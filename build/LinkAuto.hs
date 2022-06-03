{-# LANGUAGE OverloadedStrings #-}
module LinkAuto (linkAuto, linkAutoFiltered, cleanUpDivsEmpty) where

{- LinkAuto.hs: search a Pandoc document for pre-defined regexp patterns, and turn matching text into a hyperlink.
Author: Gwern Branwen
Date: 2021-06-23
When:  Time-stamp: "2022-06-02 20:27:37 gwern"
License: CC-0

This is useful for automatically defining concepts, terms, and proper names using a single master
updated list of regexp/URL pairs. (Terms like "BERT" or "GPT-3" or "RoBERTa" are too hard to all
define manually on every appearance, particularly in abstracts/annotations which themselves may be
generated automatically, so it makes more sense to try to do it automatically.)

Regexps are guarded with space/punctuation/string-end-begin delimiters, to try to avoid problems of
greedy rewrites (eg. "GAN" vs "BigGAN"). Regexps are sorted by length, longest-first, to further try
to prioritize (so "BigGAN" would match before "GAN"). For efficiency, we avoid String type
conversion as much as possible. Regexp matching is done only within a Str node; therefore,
mixed-formatting strings will not match. If a match is all inside italics/bold/smallcaps (eg. 'Emph
[Str x]'), then it will match; if a match is split (eg. '...Str x1, Emph [Str x2], ...'), then it
will fail.

A document is queried for URLs and all URLs already present or regexps without plain text matches
are removed from the rewrite dictionary. This usually lets a document be skipped entirely as having
no possible non-redundant matches.

Then, we walk the AST, running each remaining regexp against Str nodes. When there is a match, the
matching substring is then rewritten to be a Link with the URL & class `link-auto` for the first
regexp that matches.

After the regexp pass, we do an additional cleanup pass. How should we handle the case of a phrase
like "GAN" or "GPT-3" appearing potentially scores or hundreds of times in page? Do we really want
to hyperlink *all* of them? Probably not. For the cleanup pass, we track 'seen' `link-auto` links in
a Set, and if a link has been seen before, we remove it, leaving the text annotated with a simple
Span 'link-auto-skipped' class. (In the future, we may drop this clean up pass, if we can find a
good way to dynamically hide 'excess' links; one idea is define `.link-auto` CSS to de-style links,
and then, on browser screen scroll, use JS to re-link-style the first instance of each URL. So only
the first instance would be visible on each screen, minimizing redundancy/clutter/over-linking.)

Bugs: will annotate phrases inside `Header` nodes, which breaks HTML validation. Does not attempt to
handle `RawInline` or `RawBlock`, so writing raw HTML like `<a href="/Modafinil">foo</a>` will not
be detected for the purposes of rewrite-short-circuiting or possibly rewriting at all.

Dependencies: Pandoc, text, regex-tdfa, /static/build/Utils.hs, /static/build/Query.hs
-}

import Data.Char (isPunctuation)
import Data.List (nub, sortBy)
import Data.List.Split (chunksOf)
import qualified Data.Set as S (empty, fromList, insert, member, Set)
import qualified Data.Text as T (append, head, intercalate, length, last, replace, singleton, tail, init, Text)
import Control.Concurrent (getNumCapabilities)
import Control.Parallel.Strategies (parMap, rseq)
import Control.Monad.State (evalState, get, put, State)
import System.IO.Unsafe (unsafePerformIO)

import Text.Pandoc (topDown, nullAttr, Pandoc(..), Inline(Link,Image,Code,Space,Span,Str), Block(Div))
import Text.Pandoc.Walk (walkM, walk)
import Text.Regex.TDFA as R (makeRegex, match, matchTest, Regex) -- regex-tdfa supports `(T.Text,T.Text,T.Text)` instance, to avoid packing/unpacking String matches; it is maybe 4x slower than pcre-heavy, but should have fewer Unicode & correctness/segfault/strange-closure issues (native Text, and useful splitting), so to save my sanity... BUG: TDFA seems to have slow Text instances: https://github.com/haskell-hvr/regex-tdfa/issues/9

import Utils (addClass, simplifiedDoc)
import Query (extractURLs)
import Interwiki (inlinesToText)

-- test,test2 :: [Inline]
-- -- test3 = [Link ("",[],[]) [Quoted DoubleQuote [Str "Self-improving",Space,Str "reactive",Space,Str "agents",Space,Str "based",Space,Str "on",Space,Str "reinforcement",Space,Str "learning,",Space,Str "planning",Space,Str "and",Space,Str "teaching"]] ("https://citeseerx.ist.psu.edu/viewdoc/download?doi=10.1.1.75.7884&rep=rep1&type=pdf",""),Str ",",Space,Str "Lin",Space,Str "1992"]
-- test2 = [Str "It's a dilemma: at small or easy domains, StyleGAN is much faster (if not better); but at large or hard domains, mode collapse is too risky and endangers the big investment necessary to surpass StyleGAN. MuZero vs Muesli."]
-- test = [Str "bigGAN means", Space, Str "BIG", Str "GAN; you will have an easier time training a GAN on a good GPU like a P100 or a TPUv3.", Space, Str "(See",Space,Str "WP",Space,Str "on",Space,Link ("",[],[]) [Link ("",[],[]) [Str "GAN"] ("https://en.wikipedia.org/wiki/Generative_adversarial_network","")] ("https://en.wikipedia.org/wiki/Generative_adversarial_network",""),Str ").", Space, Str "Nevertheless, expensive is a GAN. See Barack Obama's presidency. Still, we shouldn't put too much weight on Barack Obama. More efficient is DistilBERT, not to be confused with", Space, Str "BERT", Str "."]
-- testDoc :: Pandoc
-- testDoc = let doc = Pandoc nullMeta [Para test] in
--             linkAuto doc

-----------

-- turn first instance of a list of regex matches into hyperlinks in a Pandoc document. NOTE: this is best run as early as possible, because it is doing raw string matching, and any formatting or changing of phrases may break a match, but after running link syntax rewrites like the interwiki links (otherwise you'll wind up inserting WP links into pages that already have that WP link, just linked as `[foo](!W)`.)
linkAuto :: Pandoc -> Pandoc
linkAuto = linkAutoFiltered id

-- if we want to run on just a subset of links (eg. remove all resulting links to Wikipedia, or delete a specific regexp match), we can pass in a filter:
linkAutoFiltered :: ([(T.Text, T.Text)] -> [(T.Text, T.Text)]) -> Pandoc -> Pandoc
linkAutoFiltered subsetter p = let customDefinitions' = filterMatches p $ filterDefinitions p (customDefinitions subsetter) in
               if null customDefinitions' then p else topDown cleanUpDivsEmpty $ topDown cleanUpSpansLinkAutoSkipped $ cleanupNestedLinks $ annotateFirstDefinitions $ walk (defineLinks customDefinitions') p

-----------

-- Walk a Pandoc document; find the first instance of every auto-definition and mark it with the HTML/CSS class `definition-auto-first`; skip any further examples of that particular defined word.
-- This lets one add CSS to highlight *just* the first definition and skip the rest; this is difficult/impossible to do in CSS alone, so requires either preprocessing  or runtime JS
annotateFirstDefinitions :: Pandoc -> Pandoc
annotateFirstDefinitions doc = evalState (walkM addFirstDefn doc) S.empty
  where addFirstDefn :: Inline -> State (S.Set T.Text) Inline
        addFirstDefn x@(Link a@(_,classes,_) il c@(t,_)) = if "link-auto" `elem` classes then
            do st <- get
               if S.member t st then return $ addClass "link-auto-skipped" $ Span nullAttr il -- Useful for debugging to annotate spans of text which *would* have been Links.
                 else do let st' = S.insert t st
                         put st'
                         return $ addClass "link-auto-first" $ Link a il c
            else return x
        addFirstDefn x = return x

-- HACK: Somehow we can, very rarely on gwern.net (maybe a dozen cases site-wide) wind up with Links nested inside of Links, despite attempts to block the substitution going too deep in `defineLinks`. This is bad, and also generates invalid HTML of nested <a><a></a></a>s.
-- I can't figure out what is going on, and this may be related to various weird issues which makes me suspect that Pandoc's traverse operations aren't *quite* defined right.
-- So, as a workaround, let's walk the AST looking for any nested Links, and erasing the Link wrapper.
cleanupNestedLinks :: Pandoc -> Pandoc
cleanupNestedLinks = topDown go
  where go :: Inline -> Inline
        go (Link (a,b,c) is (f,g)) =  Link (a,b,c) (walk goDeeper is) (f,g)
        go x = x
        -- we must be inside a Link's [Inline], so strip any Links we find for their [Inline] anchor text
        goDeeper :: Inline -> Inline
        goDeeper (Link _ is _) = Str $ inlinesToText is -- Span nullAttr is
        goDeeper x = x

-- we probably want to remove the link-auto-skipped Spans if we are not actively debugging, because they inflate the markup & browser DOM.
-- We can't just remove the Span using a 'Inline -> Inline' walk, because a Span is an Inline with an [Inline] payload, so if we just remove the Span wrapper, it is a type error: we've actually done 'Inline -> [Inline]'.
-- Block elements always have [Inline] (or [[Inline]]) and not Inline arguments if they have Inline at all; likewise, Inline element also have only [Inline] arguments.
-- So, every instance of a Span *must* be inside an [Inline]. Therefore, we can walk an [Inline], and remove the wrapper, and then before++payload++after :: [Inline] and it typechecks and doesn't change the shape.
--
-- > cleanUpSpansLinkAutoSkipped [Str "foo", Span ("",["link-auto-skipped"],[]) [Str "Bar", Emph [Str "Baz"]], Str "Quux"]
--                               [Str "foo",                                     Str "Bar", Emph [Str "Baz"],  Str "Quux"]
-- > walk cleanUpSpansLinkAutoSkipped $ Pandoc nullMeta [Para [Str "foo", Span ("",["link-auto-skipped"],[]) [Str "Bar", Emph [Str "Baz"]], Str "Quux"]]
-- Pandoc (Meta {unMeta = fromList []}) [Para [Str "foo",Str "Bar",Emph [Str "Baz"],Str "Quux"]]
--
-- NOTE: might need to generalize this to clean up other Span crud?
cleanUpSpansLinkAutoSkipped :: [Inline] -> [Inline]
cleanUpSpansLinkAutoSkipped [] = []
cleanUpSpansLinkAutoSkipped ((Span (_,["link-auto-skipped"],_) payload):rest) = payload ++ rest
cleanUpSpansLinkAutoSkipped (r:rest) = r : cleanUpSpansLinkAutoSkipped rest

cleanUpDivsEmpty :: [Block] -> [Block]
cleanUpDivsEmpty [] = []
cleanUpDivsEmpty ((Div ("",[],[]) payload):rest) = payload ++ rest
cleanUpDivsEmpty (r:rest) = r : cleanUpDivsEmpty rest -- if it is not a nullAttr, then it is important and carrying a class like "abstract" or something, and must be preserved.

-----------

defineLinks :: [(T.Text, R.Regex, T.Text)] -> [Inline] -> [Inline]
defineLinks [] x = x
defineLinks dict is = concatMap go $ mergeSpaces is
  where
   go :: Inline -> [Inline]
   go (Str "")   = []
   -- TODO: all these guards don't work; we want to skip recursion into some Inline types to avoid useless markup, but both `bottomUp`/`walk` create links anyway, and `topDown` seems to infinitely loop?
   go x@Link{}   = [x] -- skip links because can't have link inside link
   go x@Image{}  = [x] -- likewise
   go x@Code{}   = [x]
   go (Span a x) = [Span a (concatMap go x)]
   go x@(Str a)  = case findRegexMatch dict a of
                     Nothing   -> [x]
                     Just (before,"",after, _) -> go (Str before) ++ go (Str after)
                     -- NOTE: our regexps must delimit on space/punctuation, which puts the matched character *inside* `matched` instead of `before`/`after`;
                     -- unfortunately, if we move it inside the Link, this will look bad when Links get their underlining decoration
                     -- in-browser (if it's a space, it'll be a weird extended underline, and if it's punctuation, it's not usually included in a link and looks inconsistent).
                     -- So we do this song & dance to figure out if the link was *before* or *after*, remove it from the Link,
                     -- and stick a prefix or suffix replacement space/punctuation. In retrospect, it might've been better to use capture groups...
                     Just (before,matched,after, defn) ->
                       go (Str before) ++ -- NOTE: we need to recurse *before* as well after, because 'findRegexMatch' short-circuits on the first match
                                          -- but there may be a later regexp which would match somewhere in the prefix.
                       let frst = T.head matched in let lst = T.last matched in
                        (if frst == ' ' || isPunctuation frst then
                                        if lst == ' ' || isPunctuation lst then
                                          [Str $ T.singleton frst, Link ("",["link-auto"],[]) [Str $ T.init $ T.tail matched] (defn, ""), Str $ T.singleton lst] else
                                          [Str $ T.singleton frst, Link ("",["link-auto"],[]) [Str $ T.tail matched] (defn, "")]
                                      else if lst == ' ' || isPunctuation lst then
                                             [Link ("",["link-auto"],[]) [Str $ T.init matched] (defn, ""), Str $ T.singleton lst]
                                           else
                                             [Link ("",["link-auto"],[]) [Str matched] (defn, "")])
                       ++ go (Str after)
   go x          = [x]

-- Recurse through the dictionary (which should be long-first) to find the first matching regexp, since the master regexp blob matched the string.
findRegexMatch :: [(T.Text, R.Regex, T.Text)] -> T.Text -> Maybe (T.Text, T.Text, T.Text, T.Text)
findRegexMatch [] _ = Nothing
findRegexMatch ((_,r,u):rs) s = let (a,b,c) = R.match r s in
                                   if b/="" then Just (a,b,c,u) else findRegexMatch rs s

-- Pandoc breaks up strings as much as possible, like [Str "ABC", Space, "notation"], which makes it impossible to match on them, so we remove Space
mergeSpaces :: [Inline] -> [Inline]
mergeSpaces []                     = []
mergeSpaces (Str x:Str y:xs)       = mergeSpaces (Str (x`T.append`y) : xs)
mergeSpaces (Space:Str x:Space:xs) = mergeSpaces (Str (" "`T.append`x`T.append`" "):xs)
mergeSpaces (Space:Str x:xs)       = mergeSpaces (Str (" "`T.append`x):xs)
mergeSpaces (Str x:Space:xs)       = mergeSpaces (Str (x`T.append`" "):xs)
mergeSpaces (Str "":xs)            = mergeSpaces xs
mergeSpaces (x:xs)                 = x:mergeSpaces xs

-- Optimization: take a set of definitions, and a document; query document for existing URLs; if a
-- URL is already present, drop it from the definition list.
-- This avoids redundancy with links added by hand or other filters.
--
-- NOTE: This can be used to disable link rewrites by manually adding a link. In cases of self-links
-- (eg. /Modafinil will contain the word 'modafinil' and get a rewrite to /Modafinil, leading to a
-- useless self-link), it is easier to add a link to disable the rewrite than to figure out how to
-- filter out that one exact rewrite only on that page. This link can be hidden to avoid distracting
-- the reader.
-- So to disable the modafinil rewrite on /Modafinil, one could insert into the Markdown a line like:
-- `<span style="display:none;">[null](/Modafinil)</span> <!-- LinkAuto override: disable self-linking -->`
filterDefinitions :: Pandoc -> [(T.Text, R.Regex, T.Text)] -> [(T.Text, R.Regex, T.Text)]
filterDefinitions p = let allLinks = S.fromList $ map (T.replace "https://www.gwern.net/" "/") $ extractURLs p in
                                          filter (\(_,_,linkTarget) -> linkTarget `notElem` allLinks)

-- Optimization: try to prune a set of definitions and a document. Convert document to plain text,
-- and do a global search; if a regexp matches the plain text, it may or may not match the AST, but
-- if it does not match the plain text, it should never match the AST?
-- Since generally <1% of regexps will match anywhere in the document, doing a single global check
-- lets us discard that regexp completely, and not check at every node. So we can trade off doing
-- 𝑂(R × Nodes) regexp checks for doing 𝑂(R + Nodes) + plain-text-compilation, which in practice
-- turns out to be a *huge* performance gain (>30×?) here.
-- Hypothetically, we can optimize this further: we can glue together regexps to binary search the
-- list for matching regexps, giving something like 𝑂(log R) passes. Alternately, it may be possible
-- to create a 'regexp trie' where the leaves are associated with each original regexp, and search
-- the trie in parallel for all matching leaves.
filterMatches :: Pandoc -> [(T.Text, R.Regex, T.Text)] -> [(T.Text, R.Regex, T.Text)]
filterMatches p definitions  = if False then -- T.length plain < 20000 then
                                 -- for short texts like annotations, the recursive tree is extremely expensive, so just do the straight-line version:
                                 if not (matchTest allRegex plain) then []
                                 else filter (\(_,r,_) -> matchTest r plain) definitions
                               -- if long (>10k characters), we start the tree slog:
                               else filterMatch True definitions
  where
   plain :: T.Text -- cache the plain text of the document
   plain = simplifiedDoc p

   allRegex :: R.Regex
   allRegex = masterRegex definitions

   threadN :: Int
   threadN = unsafePerformIO getNumCapabilities

   regexpsMax :: Int
   regexpsMax = 32

   -- Optimization: we can glue together regexps to binary search the list for matching regexps, giving something like 𝑂(log R) passes.
   -- divide-and-conquer recursion: if we have 1 regexp left to test, test it and return if matches or empty list otherwise;
   -- if we have more than one regexp, test the full list; if none match, return empty list, otherwise, split in half, and recurse on each half.
   filterMatch :: Bool -> [(T.Text, R.Regex, T.Text)] -> [(T.Text, R.Regex, T.Text)]
   filterMatch _ [] = []
   filterMatch _ [d] = if matchTest (masterRegex [d]) plain then [d] else [] -- only one match left, base case
   -- if none of the regexps match, quit; if any match, then decide whether the remaining list is short enough to check 1 by 1, or if
   -- it is long enough that we should try to split it up into sublists and fork out the recursive call; doing a 'wide' recursion *should* be a lot faster than a binary tree
   filterMatch skipCheck ds
    -- for the very first iteration (called from `filterMatches`), we want to skip the master regex because it will be huge and slow.
    -- So, immediately break up the regexp list and descend
    | skipCheck = let subDefinitions = chunksOf ((length ds `div` threadN) `max` 2) ds
                  in concat $ parMap rseq (filterMatch False) subDefinitions
    | not (matchTest (masterRegex ds) plain) = []
    | length ds < regexpsMax || threadN == 1  = concatMap ((filterMatch False) . return) ds -- in ghci, parallelism doesn't work, so just skip when we have 1 thread (==interpreted)
    | otherwise =
      let subDefinitions = chunksOf ((length ds `div` threadN) `max` 2) ds
        in concat $ parMap rseq (filterMatch False) subDefinitions

-- create a simple heuristic master regexp using alternation out of all possible regexes, for the heuristic check 'filterMatches'. WARNING: Depending on the regex library, just alternating regexes (rather than using a regexp trie) could potentially trigger an exponential explosion in RAM usage...
masterRegex :: [(T.Text, R.Regex, T.Text)] -> R.Regex
masterRegex ds = R.makeRegex $ T.intercalate "|" $ map (\(a,_,_) -> a) ds

-- We want to match our given regexps by making them 'word-level' and matching on punctuation/whitespace delimiters. This avoids subword matches, for example, matching 'GAN' in 'StyleGAN' is undesirable.
customDefinitionsR :: [(T.Text, T.Text)] -> [(T.Text, R.Regex, T.Text)]
customDefinitionsR = map (\(a,b) -> (a,
                                      R.makeRegex $ "[[:punct:][:blank:]]"`T.append`a`T.append`"[[:punct:][:blank:]]",
                                      b))

-----------

-- validate and error out immediately if there are bad rewrites defined
definitionsValidate :: [(T.Text, T.Text)] -> [(T.Text, T.Text)]
definitionsValidate defs = if nub (map fst defs) /= map fst defs
                    then error $ "Definition keys are not unique! Definitions: " ++ show (map fst defs)
                    else if nub (map snd defs) /= map snd defs then
                           error $ "Definition values are not unique! Definitions: " ++ show (map snd defs)
                         else defs

-- Create sorted (by length) list of (string/compiled-regexp/substitution) tuples.
-- This can be filtered on the third value to remove redundant matches, and the first value can be
-- concatenated into a single master regexp.
-- Possible future feature: instead of returning a simple 'T.Text' value as the definition, which is
-- substituted by the rewrite code into a 'Link' element (the knowledge of which is hardwired), one
-- could instead return a 'T.Text -> Inline' function instead (making the type '[(T.Text, R.Regex,
-- (T.Text -> Inline))]'), to insert an arbitrary 'Inline' (not necessarily a Link, or possibly a
-- custom kind of Link). This would be a much more general form of text rewriting, which could
-- support other features, such as turning into multiple links (eg. one link for each word in a
-- phrase), abbreviated phrases (a shorthand could be expanded to a Span containing arbitrary
-- '[Inline]'), transclusion of large blocks of text, simplified DSLs of sorts, etc. The standard
-- link substitution boilerplate would be provided by a helper function like 'link :: T.Text ->
-- (T.Text -> Inline); link x = \match -> Link ... [Str match] (x,...)'.
-- I'm not sure how crazy I want to get with the rewrites, though. The regexp rewriting is expensive
-- since it must look at all text. If you're doing those sorts of other rewrites, it'd generally be
-- more sensible to require them to be marked up explicitly, which is vastly easier to program &
-- more efficient. We'll see.
customDefinitions :: ([(T.Text, T.Text)] -> [(T.Text, T.Text)]) -> [(T.Text, R.Regex, T.Text)]
customDefinitions subsetter = customDefinitionsR $ definitionsValidate $ subsetter custom -- delimit & compile

-- descending order, longest match to shortest (for regex priority):
-- WARNING: we appear to be hitting some sort of exponential slowdown despite the optimizations. From now on, delete at least one rewrite for every added rewrite. Many are unnecessary.
custom :: [(T.Text, T.Text)]
custom = sortBy (\a b -> compare (T.length $ fst b) (T.length $ fst a)) [
        ("(1-Lipschitz|Lipschitz)", "https://en.wikipedia.org/wiki/Lipschitz_continuity")
        , ("(A2C|A3C|[Aa]synchronous [Aa]dvantage [Aa]ctor-[Cc]ritic)", "https://arxiv.org/abs/1602.01783#deepmind")
        , ("(ADHD|[Aa]ttention[ -][Dd]eficit [Hh]yperactivity [Dd]isorder)s?", "https://en.wikipedia.org/wiki/Attention_deficit_hyperactivity_disorder")
        , ("(AFQT|ASVAB|Armed Forces Qualification Test|Armed Services Vocational Aptitude Battery)", "https://en.wikipedia.org/wiki/Armed_Services_Vocational_Aptitude_Battery")
        , ("(Akaike [Ii]nformation [Cc]riterion|AIC)", "https://en.wikipedia.org/wiki/Akaike_information_criterion")
        , ("(Alexey )?Guzey", "https://guzey.com/")
        , ("(Alpha ?Zero|Alpha0)", "/docs/reinforcement-learning/alphago/2018-silver.pdf#deepmind")
        , ("(Andrey )?Kolmogorov.?.?.?", "https://en.wikipedia.org/wiki/Andrey_Kolmogorov")
        , ("(Anime News Network|ANN)", "https://en.wikipedia.org/wiki/Anime_News_Network")
        , ("(ArXiv|Arxiv|arxiv)", "https://en.wikipedia.org/wiki/ArXiv")
        , ("(Arthur|A.) Jensen", "https://en.wikipedia.org/wiki/Arthur_Jensen")
        , ("(Big [Ff]ive|OCEAN|Big 5)", "https://en.wikipedia.org/wiki/Big_Five_personality_traits")
        , ("(BigGAN(-deep)s?|Brock et al 2018)", "https://arxiv.org/abs/1809.11096#deepmind")
        , ("(CBT|[Cc]ognitive[ -][Bb]ehaviou?r(al)? [Tt]herap(y|ies))", "https://en.wikipedia.org/wiki/Cognitive_behavioral_therapy")
        , ("(CNN|[Cc]onvolutional [Nn]eural [Nn]etwork)", "https://en.wikipedia.org/wiki/Convolutional_neural_network")
        , ("(COCO|MS[- ]?COCO)", "https://arxiv.org/abs/1405.0312#microsoft")
        , ("(CURL|Curl|curl)", "https://en.wikipedia.org/wiki/CURL")
        , ("(Czeslaw Milosz|Czesław Miłosz|Miłosz|Milosz)", "https://en.wikipedia.org/wiki/Czeslaw_Milosz")
        , ("(DAICON III|DAICON IV)", "https://en.wikipedia.org/wiki/Daicon_III_and_IV_Opening_Animations")
        , ("(Deep[Mm]ind.?Lab|DM[Ll]ab-30|DM[Ll]ab)", "https://arxiv.org/abs/1612.03801#deepmind")
        , ("(Dungeons (&|and) Dragons|D&D)", "https://en.wikipedia.org/wiki/Dungeons_&amp;_Dragons")
        , ("(EHR|[Ee]lectronic [Hh]ealth [Rr]ecords?)", "https://en.wikipedia.org/wiki/Electronic_health_record")
        , ("(EV|[Ee]xpected[ -][Vv]alue)", "https://en.wikipedia.org/wiki/Expected_value")
        , ("(Edward N. Luttwak|Edward Luttwak|Luttwak)", "https://en.wikipedia.org/wiki/Edward_Luttwak")
        , ("(End [Oo]f Evangelion|EoE|EOE)", "https://en.wikipedia.org/wiki/The_End_of_Evangelion")
        , ("(Everything2|E2)", "https://en.wikipedia.org/wiki/Everything2")
        , ("(Extraversion|Introversion)", "https://en.wikipedia.org/wiki/Extraversion_and_introversion")
        , ("(Fermi [Pp]roblem.?|Fermi [Qq]uestion.?)", "https://en.wikipedia.org/wiki/Fermi_problem")
        , ("(Fr[ée]chet [Ii]nception [Dd]istance|FID)", "https://en.wikipedia.org/wiki/Fr%C3%A9chet_inception_distance")
        , ("(Friedrich Nietzsche|Nietzsche)", "https://en.wikipedia.org/wiki/Friedrich_Nietzsche")
        , ("(Fujiwara (no )?Teika|Teika (no )?Fujiwara)", "https://en.wikipedia.org/wiki/Fujiwara_no_Teika")
        , ("(GSEM|[Gg]enomic SEM|[Gg]enomic [Ss]tructural [Ee]quation [Mm]odeling)", "https://www.ncbi.nlm.nih.gov/pmc/articles/PMC6520146/")
        , ("(H?P?:?MoR|Methods [Oo]f Rationality)", "https://www.hpmor.com/")
        , ("(Hacker News|HN)", "https://en.wikipedia.org/wiki/Hacker_News")
        , ("(Hamiltonian Monte Carlo|[Hh]ybrid Monte Carlo)", "https://en.wikipedia.org/wiki/Hamiltonian_Monte_Carlo")
        , ("(Hans J\\. Eysenck|Hans Jürgen Eysenck|Hans Eysenck|Eysenck[ian]?)", "https://en.wikipedia.org/wiki/Hans_Eysenck")
        , ("(Henri Poincar[ée]|Poincar[ée])", "https://en.wikipedia.org/wiki/Henri_Poincare")
        , ("(IPA|International Phonetic Alphabet)", "https://en.wikipedia.org/wiki/International_Phonetic_Alphabet")
        , ("(Incompatible Timesharing System|ITS)", "https://en.wikipedia.org/wiki/Incompatible_Timesharing_System")
        , ("(International Mathematical Olympiad|IMO)", "https://en.wikipedia.org/wiki/International_Mathematical_Olympiad")
        , ("(Internet Archive|IA)", "https://en.wikipedia.org/wiki/Internet_Archive")
        , ("(Jeff Bezos|Bezos)", "https://en.wikipedia.org/wiki/Jeff_Bezos")
        , ("(John Tukey|John W\\. Tukey|Tukey)", "https://en.wikipedia.org/wiki/John_Tukey")
        , ("(John von Neumann|von Neumann)", "https://en.wikipedia.org/wiki/John_von_Neumann")
        , ("(Jorge Luis Borges|Borges)", "https://en.wikipedia.org/wiki/Jorge_Luis_Borges")
        , ("(LDSC|LD [Ss]core [Rr]egression)", "https://www.ncbi.nlm.nih.gov/pmc/articles/PMC4495769/")
        , ("(LD|[Ll]inkage [Dd]isequilibrium|[Ll]inkage [Ee]quilibrium)", "https://en.wikipedia.org/wiki/Linkage_disequilibrium")
        , ("(LSTM|[Ll]ong [Ss]hort[ -][Tt]erm [Mm]emory)", "https://en.wikipedia.org/wiki/Long_short-term_memory")
        , ("(Leta Stetter Hollingworth|Hollingworth)", "https://en.wikipedia.org/wiki/Leta_Stetter_Hollingworth")
        , ("(Lewis Terman|Terman)", "https://en.wikipedia.org/wiki/Lewis_Terman")
        , ("(MAOI|[Mm]onoamine [Oo]xidase [Ii]nhibitor)", "https://en.wikipedia.org/wiki/Monoamine_oxidase_inhibitor")
        , ("(MCMC|[Mm]arkov [Cc]hain [Mm]onte [Cc]arlo)", "https://en.wikipedia.org/wiki/Markov_chain_Monte_Carlo")
        , ("(MCTS|Monte Carlo [Tt]ree[ -][Ss]earch|MCTS-based)", "https://en.wikipedia.org/wiki/Monte_Carlo_tree_search")
        , ("(MIRI|Machine Intelligence Research Institute)", "https://en.wikipedia.org/wiki/Machine_Intelligence_Research_Institute")
        , ("(MLP:?FIM|My Little Pony: Friendship is Magic)", "https://en.wikipedia.org/wiki/My_Little_Pony:_Friendship_Is_Magic")
        , ("(MR|[Mm]endelian[ -][Rr]andomization)", "https://en.wikipedia.org/wiki/Mendelian_randomization")
        , ("(Mamoru Oshii|Oshii)", "https://en.wikipedia.org/wiki/Mamoru_Oshii")
        , ("(NFT|[Nn]on-[Ff]ungible [Tt]oken)", "https://en.wikipedia.org/wiki/Non-fungible_token")
        , ("(NPV|[Nn]et [Pp]resent [Vv]alue)", "https://en.wikipedia.org/wiki/Net_present_value")
        , ("(Naive[ -])?Bayes(ian)? classifier.?", "https://en.wikipedia.org/wiki/Naive_Bayes_classifier")
        , ("(Neon Genesis Evangelion|NGE|NGE TV|Evangelion)", "https://en.wikipedia.org/wiki/Neon_Genesis_Evangelion")
        , ("(Nico Nico Douga|NND)", "https://en.wikipedia.org/wiki/Nico_Nico_Douga")
        , ("(Niels Bohr|Bohr)", "https://en.wikipedia.org/wiki/Niels_Bohr")
        , ("(OpenAI 5|OA ?5)", "https://openai.com/five/")
        , ("(Openness|Openness to Experience)", "https://en.wikipedia.org/wiki/Openness_to_Experience")
        , ("(PBT|[Pp]opulation[ -][Bb]ased [Tt]raining|population[ -]based (deep reinforcement)? ?learning)", "/docs/reinforcement-learning/exploration/2019-jaderberg.pdf#deepmind")
        , ("(POMDPs?|[Pp]artially [Oo]bservable [Mm]arkov [Dd]ecision [Pp]rocess?e?s)", "https://en.wikipedia.org/wiki/Partially_observable_Markov_decision_process")
        , ("(PPO|[Pp]roximal [Pp]olicy [Oo]ptimization)", "https://arxiv.org/abs/1707.06347#openai")
        , ("(PTSD|[Pp]ost.?traumatic stress disorder)", "https://en.wikipedia.org/wiki/Post-traumatic_stress_disorder")
        , ("(PaintsTransfer/)?style2paints", "https://github.com/lllyasviel/style2paints")
        , ("Paul Graham", "https://en.wikipedia.org/wiki/Paul_Graham_%28computer_programmer%29")
        , ("(Peter Thiel|Thiel)", "https://en.wikipedia.org/wiki/Peter_Thiel")
        , ("(President|Barack) Obama", "https://en.wikipedia.org/wiki/Barack_Obama")
        , ("(Pretty Good Privacy|PGP)", "https://en.wikipedia.org/wiki/Pretty_Good_Privacy")
        , ("(PubMed|PMC)", "https://en.wikipedia.org/wiki/PubMed")
        , ("(RNN|[Rr]ecurrent [Nn]eural [Nn]etwork|[Rr]ecurrent network)", "https://en.wikipedia.org/wiki/Recurrent_neural_network")
        , ("(ResNet-(18|34|50|101|152)|[Rr]es[Nn]et|[Rr]esidual[ -][Nn]etwork)s?", "https://arxiv.org/abs/1512.03385#microsoft")
        , ("(Richard Hamming|Hamming)", "https://en.wikipedia.org/wiki/Richard_Hamming")
        , ("(SAD|Seasonal [Aa]ffective [Dd]isorder)", "https://en.wikipedia.org/wiki/Seasonal_affective_disorder")
        , ("(SCZ|[Ss]chizophreni[ac]s?)", "https://en.wikipedia.org/wiki/Schizophrenia")
        , ("(SGD|[Ss]tochastic [Gg]radient [Dd]escent)", "https://en.wikipedia.org/wiki/Stochastic_gradient_descent")
        , ("(SMPY|Study [Oo]f Mathematically Precocious Youth)", "/SMPY")
        , ("(SNP|[Ss]ingle[ -][Nn]ucleotide [Pp]olymorphism)", "https://en.wikipedia.org/wiki/Single-nucleotide_polymorphism")
        , ("(SVM|[Ss]upport [Vv]ector [Mm]achines?)", "https://en.wikipedia.org/wiki/Support-vector_machine")
        , ("(Shotetsu|Shōtetsu)", "https://en.wikipedia.org/wiki/Sh%C5%8Dtetsu")
        , ("(Soft Actor-Critic|SAC)", "https://arxiv.org/abs/1801.01290")
        , ("StyleGAN2-ADA.?|Karras et al 2020", "https://arxiv.org/abs/2006.06676#nvidia")
        , ("(StyleGANs?|CelebA[ -]HQ|FFHQ)", "https://arxiv.org/abs/1812.04948#nvidia")
        , ("(TADNE|This Anime Does Not Exist\\.?a?i?)", "https://thisanimedoesnotexist.ai/")
        , ("(TFDNE|This Fursona Does Not Exist)", "https://www.thisfursonadoesnotexist.com/")
        , ("(TPDNE|This Pony Does Not Exist)", "https://thisponydoesnotexist.net/")
        , ("(TWDNE|TWDNEv2|This Waifu Does Not Exist|This ?Waifu ?Does ?Not ?Exist(\\.net)?)", "/TWDNE")
        , ("(TeX|Tex)", "https://en.wikipedia.org/wiki/TeX")
        , ("(Terman (study|sample)|Terman's|[Gg]enetic [Ss]tudies [Oo]f [Gg]enius)", "https://en.wikipedia.org/wiki/Genetic_Studies_of_Genius")
        , ("(UKBB|UK Bio ?[Bb]ank)", "https://en.wikipedia.org/wiki/UK_Biobank")
        , ("(VoI|[Vv]alue [Oo]f [Ii]nformation)", "https://en.wikipedia.org/wiki/Value_of_Information")
        , ("(W. S. Gosset|William Sealy Gosset|Student)", "https://en.wikipedia.org/wiki/William_Sealy_Gosset")
        , ("(W?GWAS?|[Gg]enome-[Ww]ide [Aa]ssociation [Aa]nalys(is|e|es)|[Gg]enome-[Ww]ide [Aa]ssociation [Ss]tud(y|ies))", "https://en.wikipedia.org/wiki/Genome-wide_association_study")
        , ("(WGAN|Wasserstein GAN)s?", "https://arxiv.org/abs/1701.07875")
        , ("(Waste Isolation Pilot Plant|WIPP)", "https://en.wikipedia.org/wiki/Waste_Isolation_Pilot_Plant")
        , ("([Aa]lgorithmic [Ii]nformation [Tt]heory|AIT)", "https://en.wikipedia.org/wiki/Algorithmic_information_theory")
        , ("([Ar]modafinil|[Mm]odafinil)", "/Modafinil")
        , ("([Bb]andit sampling|[Bb]andit models?|[Mm]ulti-[Aa]rm?e?d [Bb]andit)", "https://en.wikipedia.org/wiki/Multi-armed_bandit")
        , ("([Bb]inomial distribution|binomially)", "https://en.wikipedia.org/wiki/Binomial_distribution")
        , ("([Bb]ody [Mm]ass [Ii]ndex|BMI)", "https://en.wikipedia.org/wiki/Body_mass_index")
        , ("([Cc]entral [Ll]imit [Tt]heorem|CLT)", "https://en.wikipedia.org/wiki/Central_limit_theorem")
        , ("([Dd]ark [Nn]et [Mm]arket|[Dd]arknet [Mm]arket|DNM|[Cc]ryptomarket|[Cc]rypto-[Mm]arket)", "https://en.wikipedia.org/wiki/Darknet_market")
        , ("([Dd]enoising [Dd]iffusion [Pp]robabilistic [Mm]odels?|DDPMs?)", "https://arxiv.org/abs/2006.11239")
        , ("([Ee]fficient-[Mm]arket.? [Hh]ypothesis|[Ee]fficient[ -]market.?|EMH)", "https://en.wikipedia.org/wiki/Efficient-market_hypothesis")
        , ("([Ee]xistential[ -]risk|[Xx]-risk)", "https://en.wikipedia.org/wiki/Existential_risk")
        , ("([Ee]xome sequencing|[Ee]xomes?|[Ww]hole-exome sequencing)", "https://en.wikipedia.org/wiki/Exome_sequencing")
        , ("([Ee]xpected [Vv]alue [Oo]f [Pp]erfect [Ii]nformation|EVPI)", "https://en.wikipedia.org/wiki/Expected_value_of_perfect_information")
        , ("([Ee]xpected [Vv]alue [Oo]f [Ss]ample [Ii]nformation|EVSI)", "https://en.wikipedia.org/wiki/Expected_value_of_sample_information")
        , ("([Ee]xponential [Mm]oving [Aa]verages?|EMA)", "https://arxiv.org/abs/1806.04498")
        , ("([Ee]xponential discounting|[Ee]xponentially discounted)", "https://en.wikipedia.org/wiki/Exponential_discounting")
        , ("([Ff]ield-[Pp]rogrammable [Gg]ate [Aa]rray|FPGA)", "https://en.wikipedia.org/wiki/Field-programmable_gate_array")
        , ("([Ff]orward [Ee]rror [Cc]orrection|FEC)", "https://en.wikipedia.org/wiki/Forward_error_correction")
        , ("([Gg]amebook|CYOA)", "https://en.wikipedia.org/wiki/Gamebook")
        , ("([Gg]arbage collection|GC)", "https://en.wikipedia.org/wiki/Garbage_collection_%28computer_science%29")
        , ("([Gg]enetic correlation.?|[Gg]enetically[ -]correlated?)", "https://en.wikipedia.org/wiki/Genetic_correlations")
        , ("([Gg]enomic [Ss]election|[Mm]olecular breeding)", "https://en.wikipedia.org/wiki/Molecular_breeding")
        , ("([Gg]eometric distribution|geometrically[ -]distributed)", "https://en.wikipedia.org/wiki/Geometric_distribution")
        , ("([Gg]roup[ -]selection(ism)?|[Mm]ulti-level selection)", "https://en.wikipedia.org/wiki/Group_selection")
        , ("([Ii]nferotemporal \\(IT\\) [Cc]ortex|[Ii]nferotemporal [Cc]ortex)", "https://en.wikipedia.org/wiki/Inferior_temporal_gyrus")
        , ("([Ll]-)?[Tt]heanine.?", "https://en.wikipedia.org/wiki/Theanine")
        , ("([Ll]iability[ -]threshold model(s|ing)?|[Ll]iability[ -]thresholds?)", "https://en.wikipedia.org/wiki/Liability_threshold_model")
        , ("([Ll]ight[ -]therapy|[Pp]hototherapy)", "https://en.wikipedia.org/wiki/Light_therapy")
        , ("([Ll]ow [Ll]evel [Ll]aser [Tt]herapy|LLLT)", "https://en.wikipedia.org/wiki/Low_level_laser_therapy")
        , ("([Mm]arkov [Dd]ecision [Pp]rocess|MDP)s?", "https://en.wikipedia.org/wiki/Markov_decision_process")
        , ("([Mm]ulti-?[Ll]evel|[Hh]ierarchical linear|[Hh]ierarchical|[Ll]inear mixed[ -]effects?|[Ll]inear mixed|[Mm]ixed[ -]effects?|[Mm]ixed|[Nn]ested data|[Rr]andom-effects|[Rr]andom parameter) model(s|ing)?", "https://en.wikipedia.org/wiki/Multilevel_model")
        , ("([Nn]egative selection|[Pp]urifying selection)", "https://en.wikipedia.org/wiki/Negative_selection_(natural_selection)")
        , ("([Nn]ormal distribution.?|Gaussian distribution.?|[Nn]ormally[ -]distributed)", "https://en.wikipedia.org/wiki/Normal_distribution")
        , ("([Pp]archive|PAR|PAR2)s?", "https://en.wikipedia.org/wiki/Parchive")
        , ("([Pp]olygenic [Ss]core|PGS|[Pp]olygenic [Rr]isk [Ss]core|PRS|[Gg]enetic [Rr]isk [Ss]core|GRS|[Gg]enome-[Ww]ide [Ss]core|[Pp]olygenic [Ii]ndex|PGI)s?", "https://en.wikipedia.org/wiki/Polygenic_score")
        , ("([Pp]rompt programming|[Pp]rompt engineering)", "/GPT-3#prompts-as-programming")
        , ("([Pp]rotein.? folding|folding protein.?)", "https://en.wikipedia.org/wiki/Protein_folding")
        , ("([Qq]uantitative [Tt]rait [Ll]oci|QTLs?)", "https://en.wikipedia.org/wiki/Quantitative_trait_locus")
        , ("([Rr]ange restriction|[Rr]estricted range|[Rr]estriction of range)", "https://en.wikipedia.org/wiki/Range_restriction")
        , ("([Ss]elf-[Ss]upervised [Ll]earning|[Ss]emi-[Ss]upervised [Ll]earning)", "https://en.wikipedia.org/wiki/Semi-supervised_learning")
        , ("([Ss]tatistical [Pp]ower|well-powered)", "https://en.wikipedia.org/wiki/Statistical_power")
        , ("([Ss]tatistical[ -]significance|[Ss]tatistically-significant)", "https://en.wikipedia.org/wiki/Statistical_significance")
        , ("([Ss]tructural [Ee]quation [Mm]odel(s|ing)?|SEM)s?", "https://en.wikipedia.org/wiki/Structural_equation_modeling") -- SEM can also refer to 'scanning electron microscope' or 'standard error of the mean' in Gwern.net content, but in practice, those uses seem far rarer
        , ("([Tt]abletop [Rr]ole-[Pp]laying [Gg]ame|TTRPG)", "https://en.wikipedia.org/wiki/Tabletop_role-playing_game")
        , ("([Tt]runcated normal distribution|[Tt]runcated normal)", "https://en.wikipedia.org/wiki/Truncated_normal_distribution")
        , ("([Vv]ision [Tt]ransformers?|ViT)", "https://openreview.net/forum?id=YicbFdNTTy#google")
        , ("([Vv]isual[ -]novel|VN)", "https://en.wikipedia.org/wiki/Visual_novel")
        , ("([Ww]eight [Dd]ecay|L0|L~0~|[Rr]idge regression|𝓁<sub>1</sub>|𝓁<sub>2</sub>)", "https://en.wikipedia.org/wiki/Tikhonov_regularization")
        , ("([Ll]asso|[Ll]east absolute shrinkage and selection operator|LASSO|[Ll]asso regression)", "https://en.wikipedia.org/wiki/Lasso_(statistics)")
        , ("([Ww]orking[ -][Mm]emory|WM)", "https://en.wikipedia.org/wiki/Working_memory")
        , ("(non|anti)?-?[Ee]pilep(sy|ies|etics?)", "https://en.wikipedia.org/wiki/Epilepsy")
        , ("23[A]nd[Mm]e", "https://en.wikipedia.org/wiki/23andMe")
        , ("A. ?E. Housman", "https://en.wikipedia.org/wiki/A.E._Housman")
        , ("ABalytics", "https://github.com/danmaz74/ABalytics")
        , ("AI Dungeon", "https://play.aidungeon.io/main/home")
        , ("AIXI", "https://www.lesswrong.com/tag/aixi")
        , ("AIXI\\.?js", "https://arxiv.org/abs/1705.07615")
        , ("ALBERT", "https://arxiv.org/abs/1909.11942#google")
        , ("ALGOL[ -]?60", "https://en.wikipedia.org/wiki/ALGOL_60")
        , ("ALIGN", "https://arxiv.org/abs/2102.05918#google")
        , ("AMD", "https://en.wikipedia.org/wiki/Advanced_Micro_Devices")
        , ("A\\. ?E\\. Housman", "https://en.wikipedia.org/wiki/A._E._Housman")
        , ("Abraham Wald", "https://en.wikipedia.org/wiki/Abraham_Wald")
        , ("Ackermann function", "https://en.wikipedia.org/wiki/Ackermann_function")
        , ("Adderall", "https://en.wikipedia.org/wiki/Adderall")
        , ("Agent57", "https://arxiv.org/abs/2003.13350#deepmind")
        , ("Agreeableness", "https://en.wikipedia.org/wiki/Agreeableness")
        , ("Agrippina", "https://en.wikipedia.org/wiki/Agrippina_(opera)")
        , ("Alan Kay", "https://en.wikipedia.org/wiki/Alan_Kay")
        , ("Alan Perlis", "https://en.wikipedia.org/wiki/Alan_Perlis")
        , ("Aldous Huxley", "https://en.wikipedia.org/wiki/Aldous_Huxley")
        , ("Alexander Shulgin", "https://en.wikipedia.org/wiki/Alexander_Shulgin")
        , ("Alfred W. McCoy", "https://en.wikipedia.org/wiki/Alfred_W._McCoy")
        , ("Allegrini et al 2018", "https://www.biorxiv.org/content/10.1101/418210v1.full")
        , ("Alpha ?Go", "https://en.wikipedia.org/wiki/AlphaGo")
        , ("AlphaGo Master", "https://en.wikipedia.org/wiki/Master_(software)")
        , ("Amanda Knox", "https://en.wikipedia.org/wiki/Amanda_Knox")
        , ("Amazon S3", "https://en.wikipedia.org/wiki/Amazon_S3")
        , ("Amdahl's [Ll]aw", "https://en.wikipedia.org/wiki/Amdahl%27s_law")
        , ("Analog Science Fiction and Fact", "https://en.wikipedia.org/wiki/Analog_Science_Fiction_and_Fact")
        , ("Anders Sandberg", "https://en.wikipedia.org/wiki/Anders_Sandberg")
        , ("Andy Matuschak", "https://andymatuschak.org/")
        , ("AniSeg", "https://github.com/jerryli27/AniSeg/")
        , ("Anki", "https://en.wikipedia.org/wiki/Anki_%28software%29")
        , ("Anne Roe", "https://en.wikipedia.org/wiki/Anne_Roe")
        , ("Anthropic [Pp]rinciple", "https://en.wikipedia.org/wiki/Anthropic_principle")
        , ("Apollo 11", "https://en.wikipedia.org/wiki/Apollo_11")
        , ("Arab slave trade", "https://en.wikipedia.org/wiki/Barbary_slave_trade")
        , ("Archive ?Team", "https://en.wikipedia.org/wiki/Archive_Team")
        , ("Artbreeder", "https://www.artbreeder.com/")
        , ("Arthur C\\. Clarke", "https://en.wikipedia.org/wiki/Arthur_C._Clarke")
        , ("Arthur Schopenhauer", "https://en.wikipedia.org/wiki/Arthur_Schopenhauer")
        , ("Asuka Langley Soryu", "https://en.wikipedia.org/wiki/Asuka_Langley_Soryu")
        , ("Augur", "https://en.wikipedia.org/wiki/Augur_%28software%29")
        , ("Aum Shinrikyo", "https://en.wikipedia.org/wiki/Aum_Shinrikyo")
        , ("B-heaps?", "https://en.wikipedia.org/wiki/B-heap")
        , ("BART", "https://arxiv.org/abs/1910.13461#facebook")
        , ("BERT", "https://arxiv.org/abs/1810.04805#google")
        , ("BLEU-?[0-9]?", "https://en.wikipedia.org/wiki/BLEU")
        , ("BYOL", "https://arxiv.org/abs/2006.07733#deepmind")
        , ("Backblaze", "https://en.wikipedia.org/wiki/Backblaze")
        , ("Bakewell", "https://en.wikipedia.org/wiki/Robert_Bakewell_%28agriculturalist%29")
        , ("Bandai", "https://en.wikipedia.org/wiki/Bandai")
        , ("Barlow Twins?", "https://arxiv.org/abs/2103.03230#facebook")
        , ("Baskerville", "https://en.wikipedia.org/wiki/Baskerville")
        , ("Bayes.?.?.? ([Tt]heorem|[Ff]ormula|[Ll]aw|[Rr]ule)", "https://en.wikipedia.org/wiki/Bayes%27_theorem")
        , ("Bayesian (models?|approach|estimation|methods?|statistics?|analysis|inference)", "https://en.wikipedia.org/wiki/Bayesian_statistics")
        , ("Bayesian RL", "https://arxiv.org/abs/1609.04436")
        , ("Bayesian [Ss]earch [Tt]heory", "https://en.wikipedia.org/wiki/Bayesian_search_theory")
        , ("Bayesian decision", "https://en.wikipedia.org/wiki/Subjective_expected_utility")
        , ("Bayesian optimization", "https://en.wikipedia.org/wiki/Bayesian_optimization")
        , ("Berkson[’']s paradox", "https://en.wikipedia.org/wiki/Berkson%27s_paradox")
        , ("BiT", "https://arxiv.org/abs/1912.11370#google")
        , ("Bias in Mental Testing", "https://en.wikipedia.org/wiki/Bias_in_Mental_Testing")
        , ("BigBird", "https://arxiv.org/abs/2007.14062#google")
        , ("Bit[Tt]orrent", "https://en.wikipedia.org/wiki/BitTorrent")
        , ("Black-Scholes model", "https://en.wikipedia.org/wiki/Black%E2%80%93Scholes_model")
        , ("Blair Braverman", "https://en.wikipedia.org/wiki/Blair_Braverman")
        , ("Blender", "https://arxiv.org/abs/2004.13637#facebook")
        , ("Bonferroni correction", "https://en.wikipedia.org/wiki/Bonferroni_correction")
        , ("Book of Job", "https://en.wikipedia.org/wiki/Book_of_Job")
        , ("Brad Leithauser", "https://en.wikipedia.org/wiki/Brad_Leithauser")
        , ("Bradley.Terry model", "https://en.wikipedia.org/wiki/Bradley-Terry_model")
        , ("Brain Workshop", "http://brainworkshop.sourceforge.net/")
        , ("Bruce Schneier", "https://en.wikipedia.org/wiki/Bruce_Schneier")
        , ("Busy Beaver functions?", "https://en.wikipedia.org/wiki/Busy_beaver")
        , ("ByT5", "https://arxiv.org/abs/2105.13626#google")
        , ("C4\\.5", "https://en.wikipedia.org/wiki/C4.5_algorithm")
        , ("CC[ -]12M", "https://arxiv.org/abs/2102.08981#google")
        , ("(CLIP|Contrastive Language-Image Pre-Training)", "https://openai.com/blog/clip/")
        , ("CNVs?", "https://en.wikipedia.org/wiki/Copy-number_variation")
        , ("CPM", "https://arxiv.org/abs/2012.00413")
        , ("CPM-2", "https://arxiv.org/abs/2106.10715")
        , ("CRISPR", "https://en.wikipedia.org/wiki/CRISPR")
        , ("CRISPR/Cas9", "https://en.wikipedia.org/wiki/Cas9")
        , ("CTRL", "https://arxiv.org/abs/1909.05858#salesforce")
        , ("C\\. ?S\\. ?Lewis", "https://en.wikipedia.org/wiki/C._S._Lewis")
        , ("Carmen", "https://en.wikipedia.org/wiki/Carmen")
        , ("Catch-22", "https://en.wikipedia.org/wiki/Catch-22")
        , ("Catherynne M. Valente", "https://en.wikipedia.org/wiki/Catherynne_M._Valente")
        , ("CelebA", "http://mmlab.ie.cuhk.edu.hk/projects/CelebA.html")
        , ("Char Aznable", "https://en.wikipedia.org/wiki/Char_Aznable")
        , ("Charles Murray", "https://en.wikipedia.org/wiki/Charles_Murray_%28political_scientist%29")
        , ("Christopher Murray", "https://en.wikipedia.org/wiki/Christopher_J.L._Murray")
        , ("Cicero", "https://en.wikipedia.org/wiki/Cicero")
        , ("Claude Shannon", "https://en.wikipedia.org/wiki/Claude_Shannon")
        , ("Clay Shirky", "https://en.wikipedia.org/wiki/Clay_Shirky")
        , ("Clever Hans", "https://en.wikipedia.org/wiki/Clever_Hans")
        , ("Clock [Oo]f [Tt]he Long Now", "https://en.wikipedia.org/wiki/Clock_of_the_Long_Now")
        , ("Clune 2019", "https://arxiv.org/abs/1905.10985#uber")
        , ("CogView", "https://arxiv.org/abs/2105.13290")
        , ("Comiket", "https://en.wikipedia.org/wiki/Comiket")
        , ("ConViT", "https://arxiv.org/abs/2103.10697#facebook")
        , ("Conceptual Captions", "/docs/ai/diffusion/2018-sharma.pdf#google")
        , ("Confirmation bias", "https://en.wikipedia.org/wiki/Confirmation_bias")
        , ("Conformer", "https://arxiv.org/abs/2005.08100#google")
        , ("Conscientiousness", "https://en.wikipedia.org/wiki/Conscientiousness")
        , ("Conway's Game [Oo]f Life", "https://en.wikipedia.org/wiki/Conway%27s_Game_of_Life")
        , ("Cordwainer Smith", "https://en.wikipedia.org/wiki/Cordwainer_Smith")
        , ("Cory Doctorow", "https://en.wikipedia.org/wiki/Cory_Doctorow")
        , ("Cowboy Bebop", "https://en.wikipedia.org/wiki/Cowboy_Bebop")
        , ("Creative Commons", "https://en.wikipedia.org/wiki/Creative_Commons")
        , ("Cryptonomicon", "https://en.wikipedia.org/wiki/Cryptonomicon")
        , ("Cyphernomicon", "https://en.wikipedia.org/wiki/Cyphernomicon")
        , ("D4PG", "https://arxiv.org/abs/1804.08617#deepmind")
        , ("DALL[-·]E", "https://openai.com/blog/dall-e/")
        , ("DARPA", "https://en.wikipedia.org/wiki/DARPA")
        , ("DDPG", "https://arxiv.org/abs/1509.02971#deepmind")
        , ("DFAs?", "https://arxiv.org/abs/1609.01596")
        , ("DLRM", "https://arxiv.org/abs/2104.05158#facebook")
        , ("DQN", "https://arxiv.org/abs/1312.5602#deepmind")
        , ("Dactyl", "https://openai.com/blog/learning-dexterity/")
        , ("Dan Simmons", "https://en.wikipedia.org/wiki/Dan_Simmons")
        , ("Daniel Everett", "https://en.wikipedia.org/wiki/Daniel_Everett")
        , ("Darkleaks?", "https://github.com/darkwallet/darkleaks")
        , ("Daryl Bem", "https://en.wikipedia.org/wiki/Daryl_Bem#%22Feeling_the_Future%22_controversy")
        , ("Das Rheingold", "https://en.wikipedia.org/wiki/Das_Rheingold")
        , ("David Brin", "https://en.wikipedia.org/wiki/David_Brin")
        , ("David Foster Wallace", "https://en.wikipedia.org/wiki/David_Foster_Wallace")
        , ("David Lewis'", "https://en.wikipedia.org/wiki/David_Lewis_(philosopher)")
        , ("David Sedaris", "https://en.wikipedia.org/wiki/David_Sedaris")
        , ("DeBERTa", "https://arxiv.org/abs/2006.03654#microsoft")
        , ("Death Note", "https://en.wikipedia.org/wiki/Death_Note")
        , ("Decision Transformers?", "https://sites.google.com/berkeley.edu/decision-transformer")
        , ("Deep TAMER", "https://arxiv.org/abs/1709.10163")
        , ("Deep Voice 2", "https://arxiv.org/abs/1705.08947")
        , ("DeepDanbooru", "https://github.com/KichangKim/DeepDanbooru")
        , ("DeepSpeed", "https://github.com/microsoft/DeepSpeed")
        , ("Demis Hassabis", "https://en.wikipedia.org/wiki/Demis_Hassabis")
        , ("Der Ring des Nibelungen", "https://en.wikipedia.org/wiki/Der_Ring_des_Nibelungen")
        , ("Digi ?[Cc]ash", "https://en.wikipedia.org/wiki/DigiCash")
        , ("Dinosaur Comics", "https://en.wikipedia.org/wiki/Dinosaur_Comics")
        , ("DistilBERT", "https://arxiv.org/abs/1910.01108")
        , ("Donald Keene", "https://en.wikipedia.org/wiki/Donald_Keene")
        , ("Donald Knuth", "https://en.wikipedia.org/wiki/Donald_Knuth")
        , ("Douglas Engelbart", "https://en.wikipedia.org/wiki/Douglas_Engelbart")
        , ("Douglas Hofstadter", "https://en.wikipedia.org/wiki/Douglas_Hofstadter")
        , ("Dune", "https://en.wikipedia.org/wiki/Dune_%28novel%29")
        , ("E. ?T. Jaynes", "https://en.wikipedia.org/wiki/E.T._Jaynes")
        , ("E\\. ?O\\. ?Wilson", "https://en.wikipedia.org/wiki/E._O._Wilson")
        , ("E\\. ?T\\. ?Jaynes", "https://en.wikipedia.org/wiki/Edwin_Thompson_Jaynes")
        , ("Edward O\\. Thorp", "https://en.wikipedia.org/wiki/Edward_O._Thorp")
        , ("Edward Teller", "https://en.wikipedia.org/wiki/Edward_Teller")
        , ("Edward Thorndike", "https://en.wikipedia.org/wiki/Edward_Thorndike")
        , ("(Edward Tufte|Tufte)", "https://en.wikipedia.org/wiki/Edward_Tufte")
        , ("EfficientNet", "https://arxiv.org/abs/1905.11946#google")
        , ("Ehrlich-Simon wager", "https://en.wikipedia.org/wiki/Simon%E2%80%93Ehrlich_wager")
        , ("EigenGAN", "https://arxiv.org/abs/2104.12476")
        , ("El Ten Eleven", "https://en.wikipedia.org/wiki/El_Ten_Eleven")
        , ("Eleme", "https://en.wikipedia.org/wiki/Ele.me")
        , ("Elo rating system", "https://en.wikipedia.org/wiki/Elo_rating_system")
        , ("Emacs", "https://en.wikipedia.org/wiki/Emacs")
        , ("Epigrams in Programming", "/docs/cs/1982-perlis.pdf")
        , ("Equivalence [Pp]rinciple", "https://en.wikipedia.org/wiki/Equivalence_principle")
        , ("Eric S\\. Raymond", "https://en.wikipedia.org/wiki/Eric_S._Raymond")
        , ("Eriksen Flanker", "https://en.wikipedia.org/wiki/Eriksen_flanker_task")
        , ("Eugene Wigner", "https://en.wikipedia.org/wiki/Eugene_Wigner")
        , ("Eurisko", "https://en.wikipedia.org/wiki/Eurisko")
        , ("Evangelion 2\\.0", "https://en.wikipedia.org/wiki/Evangelion:_2.0_You_Can_(Not)_Advance")
        , ("Evangelion: 3\\.0", "https://en.wikipedia.org/wiki/Evangelion:_3.0_You_Can_(Not)_Redo")
        , ("Evernote.?", "https://en.wikipedia.org/wiki/Evernote")
        , ("Explosions [Ii]n [Tt]he Sky", "https://en.wikipedia.org/wiki/Explosions_in_the_Sky")
        , ("FAVOR\\+", "https://arxiv.org/abs/2009.14794#google")
        , ("FRACTRAN", "https://en.wikipedia.org/wiki/FRACTRAN")
        , ("Fermi (estimate|method|problem|heuristic)", "https://en.wikipedia.org/wiki/Fermi_estimate")
        , ("Fermi [Pp]aradox", "https://en.wikipedia.org/wiki/Fermi_paradox")
        , ("Feynman", "https://en.wikipedia.org/wiki/Richard_Feynman")
        , ("Flash", "https://en.wikipedia.org/wiki/Adobe_Flash")
        , ("Flickr", "https://en.wikipedia.org/wiki/Flickr")
        , ("Flowers for Algernon", "https://en.wikipedia.org/wiki/Flowers_for_Algernon")
        , ("Flynn [Ee]ffect", "https://en.wikipedia.org/wiki/Flynn_effect")
        , ("Francis Fukuyama", "https://en.wikipedia.org/wiki/Francis_Fukuyama")
        , ("Frank P. Ramsey", "https://en.wikipedia.org/wiki/Frank_Ramsey_(mathematician)")
        , ("Franz Ferdinand", "https://en.wikipedia.org/wiki/Archduke_Franz_Ferdinand_of_Austria")
        , ("FreeBSD", "https://en.wikipedia.org/wiki/FreeBSD")
        , ("Freeman Dyson", "https://en.wikipedia.org/wiki/Freeman_Dyson")
        , ("Friendship [Ii]s Optimal", "https://www.fimfiction.net/story/62074/Friendship-is-Optimal")
        , ("GAIL", "https://arxiv.org/abs/1606.03476")
        , ("GANSpace", "https://github.com/harskish/ganspace")
        , ("GANs?", "https://en.wikipedia.org/wiki/Generative_adversarial_network")
        , ("GCTA", "https://en.wikipedia.org/wiki/GCTA")
        , ("GLUE", "https://arxiv.org/abs/1804.07461")
        , ("GODIVA", "https://arxiv.org/abs/2104.14806#microsoft")
        , ("GPT-1", "https://openai.com/blog/language-unsupervised/")
        , ("GPT-2", "/docs/ai/gpt/2019-radford.pdf#openai")
        , ("GPT-3", "https://arxiv.org/abs/2005.14165#openai")
        , ("GPT-J", "https://arankomatsuzaki.wordpress.com/2021/06/04/gpt-j/")
        , ("GPT-f", "https://arxiv.org/abs/2009.03393#openai")
        , ("(OpenAI Codex|OA Codex|OA's Codex)", "https://arxiv.org/abs/2107.03374#openai")
        , ("GPipe", "https://arxiv.org/abs/1811.06965#google")
        , ("GROVER", "https://arxiv.org/abs/1905.12616#allen") -- it's an acronym, the paper writes it in all-caps even if the homepage doesn't, and 'Grover' is an unfortunately common surname; so we'll just always write "GROVER" to eliminate collisions...
        , ("GSPMD", "https://arxiv.org/abs/2105.04663#google")
        , ("GShard", "https://arxiv.org/abs/2006.16668#google")
        , ("Gainax", "https://en.wikipedia.org/wiki/Gainax")
        , ("Galton's [Pp]roblem", "https://en.wikipedia.org/wiki/Galton%27s_problem")
        , ("Gary Drescher", "https://en.wikipedia.org/wiki/Gary_Drescher")
        , ("Gaussian process", "https://en.wikipedia.org/wiki/Gaussian_process")
        , ("Ge et al 2016", "https://www.biorxiv.org/content/10.1101/070177v1.full")
        , ("Gene Wolfe", "https://en.wikipedia.org/wiki/Gene_Wolfe")
        , ("Genshiken", "https://en.wikipedia.org/wiki/Genshiken")
        , ("Geocities", "https://en.wikipedia.org/wiki/Geocities")
        , ("Georgia Tech", "https://en.wikipedia.org/wiki/Georgia_Institute_of_Technology")
        , ("Gerard Manley Hopkins", "https://en.wikipedia.org/wiki/Gerard_Manley_Hopkins")
        , ("Git[Hh]ub", "https://en.wikipedia.org/wiki/Github")
        , ("Gitit", "https://github.com/jgm/gitit")
        , ("GiveWell", "https://en.wikipedia.org/wiki/GiveWell")
        , ("Givewell", "https://en.wikipedia.org/wiki/Givewell")
        , ("Global Burden of Disease", "https://en.wikipedia.org/wiki/Global_burden_of_disease")
        , ("Go[- ]?Explore", "https://arxiv.org/abs/1901.10995#uber")
        , ("Gompertz", "https://en.wikipedia.org/wiki/Gompertz%E2%80%93Makeham_law_of_mortality")
        , ("GoodReads", "https://en.wikipedia.org/wiki/GoodReads")
        , ("Google Reader", "https://en.wikipedia.org/wiki/Google_Reader")
        , ("Google Surveys", "https://en.wikipedia.org/wiki/Google_Surveys")
        , ("Great Comet of 1680", "https://en.wikipedia.org/wiki/Great_Comet_of_1680")
        , ("Great Divergence", "https://en.wikipedia.org/wiki/Great_Divergence")
        , ("Greg Egan", "https://en.wikipedia.org/wiki/Greg_Egan")
        , ("Gregory Clark", "https://en.wikipedia.org/wiki/Gregory_Clark_%28economist%29")
        , ("Guide[Ss]tar", "https://en.wikipedia.org/wiki/GuideStar")
        , ("Gunbuster", "https://en.wikipedia.org/wiki/Gunbuster")
        , ("Hans Moravec", "https://en.wikipedia.org/wiki/Hans_Moravec")
        , ("Hayao Miyazaki", "https://en.wikipedia.org/wiki/Hayao_Miyazaki")
        , ("Henry Darger", "https://en.wikipedia.org/wiki/Henry_Darger")
        , ("Hermann Hesse", "https://en.wikipedia.org/wiki/Hermann_Hesse")
        , ("Hex", "https://en.wikipedia.org/wiki/Hex_(board_game)")
        , ("Hideaki Anno", "https://en.wikipedia.org/wiki/Hideaki_Anno")
        , ("Hideo Azuma", "https://en.wikipedia.org/wiki/Hideo_Azuma")
        , ("Higurashi", "https://en.wikipedia.org/wiki/Higurashi_When_They_Cry")
        , ("Hiroki Azuma", "https://en.wikipedia.org/wiki/Hiroki_Azuma")
        , ("Hiroshi Miyauchi", "https://en.wikipedia.org/wiki/Hiroshi_Miyauchi")
        , ("Hiroyuki Yamaga", "https://en.wikipedia.org/wiki/Hiroyuki_Yamaga")
        , ("Homeric Question", "https://en.wikipedia.org/wiki/Homeric_Question")
        , ("Hsu 2014", "https://arxiv.org/abs/1408.3421")
        , ("Hugh Everett", "https://en.wikipedia.org/wiki/Hugh_Everett_III")
        , ("Hwang Woo-suk", "https://en.wikipedia.org/wiki/Hwang_Woo-suk")
        , ("Hyperion Cantos", "https://en.wikipedia.org/wiki/Hyperion_Cantos")
        , ("I. A. Richards", "https://en.wikipedia.org/wiki/I._A._Richards")
        , ("I. J. Good", "https://en.wikipedia.org/wiki/I._J._Good")
        , ("IBM Plex", "https://en.wikipedia.org/wiki/IBM_Plex")
        , ("ID3", "https://en.wikipedia.org/wiki/ID3_algorithm")
        , ("IMPALA", "https://arxiv.org/abs/1802.01561#deepmind")
        , ("(ILSVRC|Image[Nn]et)", "https://arxiv.org/abs/1409.0575")
        , ("PASCAL (VOC|Visual Object Classes)", "http://host.robots.ox.ac.uk/pascal/VOC/")
        , ("Infinite Jest", "https://en.wikipedia.org/wiki/Infinite_Jest")
        , ("Infinite in All Directions", "https://en.wikipedia.org/wiki/Infinite_in_All_Directions")
        , ("Inflation\\.hs", "/static/build/Inflation.hs")
        , ("Intel", "https://en.wikipedia.org/wiki/Intel")
        , ("Intrade", "https://en.wikipedia.org/wiki/Intrade")
        , ("J\\. ?B\\. ?S\\. Haldane", "https://en.wikipedia.org/wiki/J._B._S._Haldane")
        , ("J\\. ?G\\. ?Ballard", "https://en.wikipedia.org/wiki/J._G._Ballard")
        , ("J\\. ?K\\. ?Rowling", "https://en.wikipedia.org/wiki/J._K._Rowling")
        , ("Jargon File", "https://en.wikipedia.org/wiki/Jargon_File")
        , ("Jeanne Calment", "https://en.wikipedia.org/wiki/Jeanne_Calment")
        , ("John D\\. Arnold", "https://en.wikipedia.org/wiki/John_D._Arnold")
        , ("John L\\. Leal", "https://en.wikipedia.org/wiki/John_L._Leal")
        , ("Joseph Conrad", "https://en.wikipedia.org/wiki/Joseph_Conrad")
        , ("Joseph Heller", "https://en.wikipedia.org/wiki/Joseph_Heller")
        , ("Joseph Tainter", "https://en.wikipedia.org/wiki/Joseph_Tainter")
        , ("Juke[Bb]ox", "https://openai.com/blog/jukebox/")
        , ("Julian Assange", "https://en.wikipedia.org/wiki/Julian_Assange")
        , ("Julian Simon", "https://en.wikipedia.org/wiki/Julian_Lincoln_Simon")
        , ("Kaplan et al 2020", "https://arxiv.org/abs/2001.08361#openai")
        , ("Kaplan-Meier", "https://en.wikipedia.org/wiki/Kaplan%E2%80%93Meier_estimator")
        , ("Kazutaka Miyatake", "https://en.wikipedia.org/wiki/Kazutaka_Miyatake")
        , ("Kelly criterion", "https://en.wikipedia.org/wiki/Kelly_criterion")
        , ("Kevin Kelly", "https://en.wikipedia.org/wiki/Kevin_Kelly_(editor)")
        , ("Kicks Condor", "https://www.kickscondor.com/")
        , ("Kinect", "https://en.wikipedia.org/wiki/Kinect")
        , ("Kirk Allen", "https://en.wikipedia.org/wiki/Kirk_Allen")
        , ("Known Space", "https://en.wikipedia.org/wiki/Known_Space")
        , ("Kolmogorov axioms", "https://en.wikipedia.org/wiki/Probability_axioms")
        , ("Krummhörn", "https://en.wikipedia.org/wiki/Krummh%C3%B6rn")
        , ("LAMBADA", "https://arxiv.org/abs/1606.06031")
        , ("LD ?Hub", "http://ldsc.broadinstitute.org/about/")
        , ("LaTeX", "https://en.wikipedia.org/wiki/LaTeX")
        , ("Laplace approximations?", "https://en.wikipedia.org/wiki/Laplace%27s_method")
        , ("Larry Niven", "https://en.wikipedia.org/wiki/Larry_Niven")
        , ("Lawrence Bragg", "https://en.wikipedia.org/wiki/Lawrence_Bragg")
        , ("Le Roy Ladurie", "https://en.wikipedia.org/wiki/Emmanuel_Le_Roy_Ladurie")
        , ("Leonard Horner", "https://en.wikipedia.org/wiki/Leonard_Horner")
        , ("Less ?Wrong", "https://www.lesswrong.com")
        , ("Libri-Light", "https://arxiv.org/abs/1912.07875#facebook")
        , ("Lisp [Mm]achines?", "https://en.wikipedia.org/wiki/Lisp_machine")
        , ("(Unix|UNIX)", "https://en.wikipedia.org/wiki/Unix")
        , ("(Lisp programming language|Lisp language|LISP|Lisp)", "https://en.wikipedia.org/wiki/Lisp_(programming_language)")
        , ("(Haskell programming language|Haskell language|Haskell)", "https://en.wikipedia.org/wiki/Haskell_(programming_language)")
        , ("Lord's [Pp]aradox", "https://en.wikipedia.org/wiki/Lord%27s_paradox")
        , ("Lotka's [Ll]aw", "https://en.wikipedia.org/wiki/Lotka%27s_law")
        , ("Lucretius", "https://en.wikipedia.org/wiki/Lucretius")
        , ("Lyft", "https://en.wikipedia.org/wiki/Lyft")
        , ("MANOVA", "https://en.wikipedia.org/wiki/MANOVA")
        , ("MDMA", "https://en.wikipedia.org/wiki/MDMA")
        , ("MEMORIZE", "http://learning.mpi-sws.org/memorize/")
        , ("MIDI", "https://en.wikipedia.org/wiki/MIDI")
        , ("MIT [Ll]icense", "https://en.wikipedia.org/wiki/MIT_License")
        , ("MLP-?Mixers?", "https://arxiv.org/abs/2105.01601#google")
        , ("MSG-GAN", "https://arxiv.org/abs/1903.06048")
        , ("Machiavelli", "https://en.wikipedia.org/wiki/Niccol%C3%B2_Machiavelli")
        , ("Machiavellianism", "https://en.wikipedia.org/wiki/Machiavellianism_(psychology)")
        , ("Madama Butterfly", "https://en.wikipedia.org/wiki/Madama_Butterfly")
        , ("Magnus Carlsen", "https://en.wikipedia.org/wiki/Magnus_Carlsen")
        , ("Mahiro Maeda", "https://en.wikipedia.org/wiki/Mahiro_Maeda")
        , ("Many[ -][Ww]orlds [Ii]nterpretation", "https://en.wikipedia.org/wiki/Many-worlds_interpretation")
        , ("Marc Andreessen", "https://en.wikipedia.org/wiki/Marc_Andreessen")
        , ("Mark Pilgrim", "https://en.wikipedia.org/wiki/Mark_Pilgrim")
        , ("Markdown", "https://en.wikipedia.org/wiki/Markdown")
        , ("Matthew effects?", "https://en.wikipedia.org/wiki/Matthew_effect")
        , ("Medici [Bb]ank", "https://en.wikipedia.org/wiki/Medici_Bank")
        , ("Meena", "https://arxiv.org/abs/2001.09977#google")
        , ("Megatron(LM)?", "https://nv-adlr.github.io/MegatronLM")
        , ("Met HD", "https://en.wikipedia.org/wiki/Metropolitan_Opera_Live_in_HD")
        , ("Meta[Mm]ath", "https://en.wikipedia.org/wiki/Metamath")
        , ("Michael Nielsen", "https://michaelnielsen.org/")
        , ("Mike Darwin", "https://en.wikipedia.org/wiki/Mike_Darwin")
        , ("Mike Power", "http://mikepower.pressfolios.com/")
        , ("Mind Sparke", "http://www.mindsparke.com/")
        , ("Minecraft", "https://en.wikipedia.org/wiki/Minecraft")
        , ("Mnemosyne", "https://en.wikipedia.org/wiki/Mnemosyne_%28software%29")
        , ("Mobile Suit Gundam", "https://en.wikipedia.org/wiki/Mobile_Suit_Gundam")
        , ("Modern Synthesis", "https://en.wikipedia.org/wiki/Neo-Darwinism")
        , ("Moebius-like", "https://en.wikipedia.org/wiki/Jean_Giraud")
        , ("MojoNation", "https://en.wikipedia.org/wiki/MojoNation")
        , ("Montaillou: The Promised Land of Error", "https://en.wikipedia.org/wiki/Montaillou_(book)")
        , ("Monte Carlo (simulates?|estimates?|simulations?|approximations?|implementations?|methods?)?", "https://en.wikipedia.org/wiki/Monte_Carlo_method")
        , ("Monte Carlo algorithm", "https://en.wikipedia.org/wiki/Monte_Carlo_algorithm")
        , ("Moore's [Ll]aw", "https://en.wikipedia.org/wiki/Moore%27s_law")
        , ("Moravec's paradox", "https://en.wikipedia.org/wiki/Moravec%27s_paradox")
        , ("Mt\\. ?Gox", "https://en.wikipedia.org/wiki/Mt._Gox")
        , ("Mu[Zz]ero Unplugged", "https://arxiv.org/abs/2104.06294#deepmind")
        , ("Mu[Zz]ero", "https://arxiv.org/abs/1911.08265#deepmind") -- MuZero
        , ("Muesli", "https://arxiv.org/abs/2104.06159")
        , ("Muji", "https://en.wikipedia.org/wiki/Muji")
        , ("Murphy's [Ll]aw", "https://en.wikipedia.org/wiki/Murphy%27s_law")
        , ("Muse[Nn]et", "https://openai.com/blog/musenet/")
        , ("Music Transformers?", "https://arxiv.org/abs/1809.04281#google")
        , ("NHK", "https://en.wikipedia.org/wiki/NHK")
        , ("NP[ -][Hh]ard", "https://en.wikipedia.org/wiki/NP-hard")
        , ("NVAE", "https://arxiv.org/abs/2007.03898#nvidia")
        , ("Narcissis(m|t|tic)", "https://en.wikipedia.org/wiki/Narcissism")
        , ("Nate Silver", "https://en.wikipedia.org/wiki/Nate_Silver")
        , ("NeRF", "https://arxiv.org/abs/2003.08934")
        , ("Neal Stephenson", "https://en.wikipedia.org/wiki/Neal_Stephenson")
        , ("Neil Gaiman", "https://en.wikipedia.org/wiki/Neil_Gaiman")
        , ("Neuroticism", "https://en.wikipedia.org/wiki/Neuroticism")
        , ("New Yorker", "https://en.wikipedia.org/wiki/The_New_Yorker")
        , ("Newcomb's Problem", "https://en.wikipedia.org/wiki/Newcomb%27s_paradox")
        , ("Nick Bostrom", "https://en.wikipedia.org/wiki/Nick_Bostrom")
        , ("Norbert Wiener", "https://en.wikipedia.org/wiki/Norbert_Wiener")
        , ("Oliver Heaviside", "https://en.wikipedia.org/wiki/Oliver_Heaviside")
        , ("OpenAI API", "https://openai.com/blog/openai-api/")
        , ("OpenAI Gym", "https://github.com/openai/gym")
        , ("OpenAI", "https://en.wikipedia.org/wiki/OpenAI")
        , ("OpenBSD", "https://en.wikipedia.org/wiki/OpenBSD")
        , ("Openness to [Ee]xperience", "https://en.wikipedia.org/wiki/Openness_to_experience")
        , ("Orson Scott Card", "https://en.wikipedia.org/wiki/Orson_Scott_Card")
        , ("Otaku no Video", "https://en.wikipedia.org/wiki/Otaku_no_Video")
        , ("Overcoming ?Bias", "https://www.overcomingbias.com/")
        , ("PILCO", "/docs/reinforcement-learning/exploration/2011-deisenroth.pdf")
        , ("PNSR", "https://en.wikipedia.org/wiki/Peak_signal-to-noise_ratio")
        , ("Pareto distribution", "https://en.wikipedia.org/wiki/Pareto_distribution")
        , ("Patreon", "https://en.wikipedia.org/wiki/Patreon")
        , ("Paul Atreides", "https://en.wikipedia.org/wiki/Paul_Atreides")
        , ("Paul Ehrlich", "https://en.wikipedia.org/wiki/Paul_R._Ehrlich")
        , ("Paul F?\\.? Christiano", "https://paulfchristiano.com/")
        , ("Pay[Pp]al", "https://en.wikipedia.org/wiki/PayPal")
        , ("Peter Singer", "https://en.wikipedia.org/wiki/Peter_Singer")
        , ("Peter Watts", "https://en.wikipedia.org/wiki/Peter_Watts_%28author%29")
        , ("Poisson distribution", "https://en.wikipedia.org/wiki/Poisson_distribution")
        , ("Polderman et al 2015", "/docs/genetics/heritable/2015-polderman.pdf")
        , ("Portia", "https://en.wikipedia.org/wiki/Portia_(spider)")
        , ("PostScript", "https://en.wikipedia.org/wiki/PostScript")
        , ("Prediction[Bb]ook.com", "https://predictionbook.com/")
        , ("Prisoner's [Dd]ilemma", "https://en.wikipedia.org/wiki/Prisoner%27s_dilemma")
        , ("ProGANs?", "https://arxiv.org/abs/1710.10196#nvidia")
        , ("Project 100,000", "https://en.wikipedia.org/wiki/Project_100,000")
        , ("Project Xanadu", "https://en.wikipedia.org/wiki/Project_Xanadu")
        , ("Puccini", "https://en.wikipedia.org/wiki/Giacomo_Puccini")
        , ("Quantified Self", "https://en.wikipedia.org/wiki/Quantified_Self")
        , ("QuickCheck", "https://en.wikipedia.org/wiki/QuickCheck")
        , ("R\\. ?A\\. ?Fisher", "https://en.wikipedia.org/wiki/Ronald_Fisher")
        , ("R\\. ?A\\. ?Lafferty", "https://en.wikipedia.org/wiki/R._A._Lafferty")
        , ("R2D2", "https://openreview.net/forum?id=r1lyTjAqYX#deepmind")
        , ("R2D3", "https://arxiv.org/abs/1909.01387#deepmind")
        , ("RAND", "https://en.wikipedia.org/wiki/RAND_Corporation")
        , ("REALM", "https://kentonl.com/pub/gltpc.2020.pdf#google")
        , ("REINFORCE", "/docs/reinforcement-learning/model-free/1992-williams.pdf")
        , ("ROUGE", "https://en.wikipedia.org/wiki/ROUGE_(metric)")
        , ("R[Ee][Ll][Uu]", "https://en.wikipedia.org/wiki/Rectifier_(neural_networks)")
        , ("R[Oo]BERT[aA]", "https://arxiv.org/abs/1907.11692#facebook") -- RoBERTa
        , ("R\\. Scott Bakker", "https://en.wikipedia.org/wiki/R._Scott_Bakker")
        , ("RandAugment", "https://arxiv.org/abs/1909.13719#google")
        , ("Randall Jarrell", "https://en.wikipedia.org/wiki/Randall_Jarrell")
        , ("Re[Zz]ero", "https://arxiv.org/abs/2003.04887")
        , ("Rebuild [Oo]f Evangelion", "https://en.wikipedia.org/wiki/Rebuild_of_Evangelion")
        , ("Red Delicious", "https://en.wikipedia.org/wiki/Red_Delicious")
        , ("Reformer", "https://arxiv.org/abs/2001.04451#google")
        , ("RegNet", "https://arxiv.org/abs/2003.13678#facebook")
        , ("([Rr]egistered [Rr]eports?|[Pp]re-?regist(ered|er|ering|ration))", "https://en.wikipedia.org/wiki/Preregistration_(science)#Registered_reports")
        , ("Res[Nn]e[Xx]t", "https://arxiv.org/abs/1907.07640")
        , ("Richard Dawkins", "https://en.wikipedia.org/wiki/Richard_Dawkins")
        , ("Rietveld et al 2013", "/docs/iq/2013-rietveld.pdf")
        , ("Robert Bakewell", "https://en.wikipedia.org/wiki/Robert_Bakewell_(agriculturalist)")
        , ("Robin Hanson", "https://en.wikipedia.org/wiki/Robin_Hanson")
        , ("Ross (William )?Ulbricht", "https://en.wikipedia.org/wiki/Ross_Ulbricht")
        , ("Rotten\\.com", "https://en.wikipedia.org/wiki/Rotten.com")
        , ("Russian domesticated foxe?s?", "https://en.wikipedia.org/wiki/Domesticated_red_fox")
        , ("SAGAN", "https://arxiv.org/abs/1805.08318")
        , ("SAT [Ss]olv(ing|ers?)", "https://en.wikipedia.org/wiki/Boolean_satisfiability_problem#Algorithms_for_solving_SAT")
        , ("SHA-256", "https://en.wikipedia.org/wiki/SHA-256")
        , ("SMYRF", "https://arxiv.org/abs/2010.05315")
        , ("SPIRAL", "https://arxiv.org/abs/1804.01118#deepmind")
        , ("SR3", "https://arxiv.org/abs/2104.07636#google")
        , ("SSIM", "https://en.wikipedia.org/wiki/Structural_similarity")
        , ("STL-10", "https://cs.stanford.edu/~acoates/stl10/")
        , ("SWA", "https://arxiv.org/abs/1803.05407")
        , ("Saddam Hussein", "https://en.wikipedia.org/wiki/Saddam_Hussein")
        , ("Samuel Johnson", "https://en.wikipedia.org/wiki/Samuel_Johnson")
        , ("(Satoshi Nakamoto|Nakamoto)", "https://en.wikipedia.org/wiki/Satoshi_Nakamoto")
        , ("Saul Kripke", "https://en.wikipedia.org/wiki/Saul_Kripke")
        , ("Schelling point", "https://en.wikipedia.org/wiki/Focal_point_(game_theory)")
        , ("Scott Aaronson", "https://en.wikipedia.org/wiki/Scott_Aaronson")
        , ("Scott Alexander", "https://astralcodexten.substack.com/")
        , ("Scott Sumner", "https://en.wikipedia.org/wiki/Scott_Sumner")
        , ("Seymour Cray", "https://en.wikipedia.org/wiki/Seymour_Cray")
        , ("Shawn Bradley", "https://en.wikipedia.org/wiki/Shawn_Bradley")
        , ("Shawn Presser", "https://nitter.hu/theshawwn")
        , ("Shinji Ikari", "https://en.wikipedia.org/wiki/Shinji_Ikari")
        , ("Shortformer", "https://arxiv.org/abs/2012.15832")
        , ("SimC[Ll][Rr]", "https://arxiv.org/abs/2002.05709#google")
        , ("Simpson's [Pp]aradox", "https://en.wikipedia.org/wiki/Simpson%27s_paradox")
        , ("Single[Ff]ile", "https://github.com/gildas-lormeau/SingleFile/")
        , ("Singularity", "https://en.wikipedia.org/wiki/Technological_singularity")
        , ("Slender Man stabbing.?", "https://en.wikipedia.org/wiki/Slender_Man_stabbing")
        , ("[Ss]nowclone", "https://en.wikipedia.org/wiki/Snowclone")
        , ("Source Sans Pro", "https://en.wikipedia.org/wiki/Source_Sans_Pro")
        , ("Source Serif Pro", "https://en.wikipedia.org/wiki/Source_Serif_Pro")
        , ("Space Battleship Yamato", "https://en.wikipedia.org/wiki/Space_Battleship_Yamato")
        , ("StackGAN", "https://arxiv.org/abs/1612.03242")
        , ("StackGAN\\+\\+", "https://arxiv.org/abs/1710.10916")
        , ("Stacy Schiff", "https://en.wikipedia.org/wiki/Stacy_Schiff")
        , ("Stanislaw Ulam", "https://en.wikipedia.org/wiki/Stanislaw_Ulam")
        , ("Stephen LaBerge", "https://en.wikipedia.org/wiki/Stephen_LaBerge")
        , ("Stephen Schneider", "https://en.wikipedia.org/wiki/Stephen_Schneider")
        , ("Stephenie Meyer", "https://en.wikipedia.org/wiki/Stephenie_Meyer")
        , ("Steve Jobs", "https://en.wikipedia.org/wiki/Steve_Jobs")
        , ("Steven Pinker", "https://en.wikipedia.org/wiki/Steven_Pinker")
        , ("Stewart Brand", "https://en.wikipedia.org/wiki/Stewart_Brand")
        , ("Stripe", "https://en.wikipedia.org/wiki/Stripe_%28company%29")
        , ("Stroop ([Ee]ffect|[Tt]ask)", "https://en.wikipedia.org/wiki/Stroop_effect")
        , ("Studio Ghibli", "https://en.wikipedia.org/wiki/Studio_Ghibli")
        , ("StyleGAN2s?", "https://arxiv.org/abs/1912.04958#nvidia")
        , ("Super(GLUE|Glue)", "https://arxiv.org/abs/1905.00537")
        , ("Suphx", "https://arxiv.org/abs/2003.13590#microsoft")
        , ("SwAV", "https://arxiv.org/abs/2006.09882#facebook")
        , ("Swee[Tt]ango", "https://en.wikipedia.org/wiki/SweeTango")
        , ("Switch Transformers?", "https://arxiv.org/abs/2101.03961#google")
        , ("T5s?", "https://arxiv.org/abs/1910.10683#google")
        , ("TF?RC", "https://sites.research.google/trc/")
        , ("TPU-?v2s?(-[0-9]+)?", "https://en.wikipedia.org/wiki/Tensor_Processing_Unit#Second_generation_TPU")
        , ("TPU-?v3s?(-[0-9]+)?", "https://en.wikipedia.org/wiki/Tensor_Processing_Unit#Third_generation_TPU")
        , ("TPU-?v4s?(-[0-9]+)?", "https://en.wikipedia.org/wiki/Tensor_Processing_Unit#Fourth_generation_TPU")
        , ("TPUs?(-[0-9]+)?", "/docs/ai/scaling/hardware/2020-jouppi.pdf#google")
        , ("Ted Chiang", "https://en.wikipedia.org/wiki/Ted_Chiang")
        , ("Terence Tao", "https://en.wikipedia.org/wiki/Terence_Tao")
        , ("[Tt]extual criticism", "https://en.wikipedia.org/wiki/Textual_criticism")
        , ("The Atlantic", "https://en.wikipedia.org/wiki/The_Atlantic")
        , ("The Book of the New Sun", "https://en.wikipedia.org/wiki/The_Book_of_the_New_Sun")
        , ("The Browser", "https://thebrowser.com/")
        , ("The Elements of Typographic Style", "https://en.wikipedia.org/wiki/The_Elements_of_Typographic_Style")
        , ("The Library of Babel", "https://en.wikipedia.org/wiki/The_Library_of_Babel")
        , ("The Literary Digest#Presidential poll", "https://en.wikipedia.org/wiki/The_Literary_Digest#Presidential_poll")
        , ("The Matrix", "https://en.wikipedia.org/wiki/The_Matrix")
        , ("The Melancholy of Haruhi Suzumiya", "https://en.wikipedia.org/wiki/The_Melancholy_of_Haruhi_Suzumiya")
        , ("The Mother of All Demos", "https://en.wikipedia.org/wiki/The_Mother_of_All_Demos")
        , ("[Tt]he Pile", "https://arxiv.org/abs/2101.00027")
        , ("The Unreasonable Effectiveness [Oo]f Mathematics [Ii]n the Natural Sciences", "https://en.wikipedia.org/wiki/The_Unreasonable_Effectiveness_of_Mathematics_in_the_Natural_Sciences")
        , ("The World [Aa]s Will [Aa]nd Representation", "https://en.wikipedia.org/wiki/The_World_as_Will_and_Representation")
        , ("[Tt]heodic(y|ies)", "https://en.wikipedia.org/wiki/Theodicy")
        , ("They Shall Not Grow Old", "https://en.wikipedia.org/wiki/They_Shall_Not_Grow_Old")
        , ("Thomas Browne", "https://en.wikipedia.org/wiki/Thomas_Browne")
        , ("Thompson [Ss]ampling", "https://en.wikipedia.org/wiki/Thompson_sampling")
        , ("Thrawn [Tt]rilogy", "https://en.wikipedia.org/wiki/Thrawn_trilogy")
        , ("Tim Powers", "https://en.wikipedia.org/wiki/Tim_Powers")
        , ("Timothy C\\. May", "https://en.wikipedia.org/wiki/Timothy_C._May")
        , ("TinyBERT", "https://arxiv.org/abs/1909.10351")
        , ("Tom Wolfe", "https://en.wikipedia.org/wiki/Tom_Wolfe")
        , ("Tommy Wiseau", "https://en.wikipedia.org/wiki/Tommy_Wiseau")
        , ("Tor", "https://en.wikipedia.org/wiki/Tor_%28anonymity_network%29")
        , ("Toshio Okada", "https://en.wikipedia.org/wiki/Toshio_Okada")
        , ("Touhou", "https://en.wikipedia.org/wiki/Touhou_Project")
        , ("TransGAN", "https://arxiv.org/abs/2102.07074")
        , ("Transformer-XLs?", "https://arxiv.org/abs/1901.02860")
        , ("Transformers?", "https://arxiv.org/abs/1706.03762#google")
        , ("Trithemius", "https://en.wikipedia.org/wiki/Johannes_Trithemius")
        , ("True[Tt]ype", "https://en.wikipedia.org/wiki/TrueType")
        , ("Trusted[ -][Tt]imestamping", "https://en.wikipedia.org/wiki/Trusted_timestamping")
        , ("Tufte[- ]CSS", "https://edwardtufte.github.io/tufte-css/")
        , ("Turandot", "https://en.wikipedia.org/wiki/Turandot")
        , ("Turing-NLG", "https://www.microsoft.com/en-us/research/blog/turing-nlg-a-17-billion-parameter-language-model-by-microsoft/")
        , ("Tyler Cowen", "https://en.wikipedia.org/wiki/Tyler_Cowen")
        , ("U-[Nn]et", "https://en.wikipedia.org/wiki/U-Net")
        , ("UCI [Rr]epository", "https://en.wikipedia.org/wiki/University_of_California,_Irvine#Machine_Learning_Repository")
        , ("Uber", "https://en.wikipedia.org/wiki/Uber")
        , ("Umberto Eco", "https://en.wikipedia.org/wiki/Umberto_Eco")
        , ("Universal Transformers?", "https://arxiv.org/abs/1807.03819#googledeepmind")
        , ("Unsong", "https://unsongbook.com/")
        , ("Usenet", "https://en.wikipedia.org/wiki/Usenet")
        , ("V100", "https://en.wikipedia.org/wiki/Volta_(microarchitecture)#Products")
        , ("VGG(-?16)", "https://arxiv.org/abs/1409.1556")
        , ("([Vv]ector [Qq]uantized [Vv]ariational [Aa]uto[Ee]ncoder|VQ-VAE)(-?[:graph:]+)?.?", "https://arxiv.org/abs/1906.00446#deepmind")
        , ("Vi[Zz][Dd]oom", "https://arxiv.org/abs/1605.02097")
        , ("VideoGPT", "https://arxiv.org/abs/2104.10157")
        , ("Virtual You[Tt]uber", "https://en.wikipedia.org/wiki/Virtual_YouTuber")
        , ("Vocaloid", "https://en.wikipedia.org/wiki/Vocaloid")
        , ("WISC(-I|-II|-III|-IV|-V|-VI)?", "https://en.wikipedia.org/wiki/Wechsler_Intelligence_Scale_for_Children")
        , ("Waifu Labs", "https://waifulabs.com/")
        , ("Walt Disney", "https://en.wikipedia.org/wiki/Walt_Disney")
        , ("Warren Buffett", "https://en.wikipedia.org/wiki/Warren_Buffett")
        , ("Web[Vv]ision", "https://arxiv.org/abs/1708.02862")
        , ("Wen[Ll]an", "https://arxiv.org/abs/2103.06561")
        , ("Western Union", "https://en.wikipedia.org/wiki/Western_Union")
        , ("William Gibson", "https://en.wikipedia.org/wiki/William_Gibson")
        , ("Wired", "https://en.wikipedia.org/wiki/Wired_%28magazine%29")
        , ("Wisconsin Longitudinal Study", "https://www.ssc.wisc.edu/wlsresearch/about/description.php")
        , ("Wittgenstein", "https://en.wikipedia.org/wiki/Ludwig_Wittgenstein")
        , ("Worm", "https://parahumans.wordpress.com/category/stories-arcs-1-10/arc-1-gestation/1-01/")
        , ("XLM-R", "https://arxiv.org/abs/1911.02116#facebook")
        , ("XL[Nn]et", "https://arxiv.org/abs/1906.08237")
        , ("XMC-GAN", "https://arxiv.org/abs/2101.04702#google")
        , ("X[Mm]onad", "https://en.wikipedia.org/wiki/Xmonad")
        , ("Yasuhiro Takeda", "https://en.wikipedia.org/wiki/Yasuhiro_Takeda")
        , ("Yoshiyuki Tomino", "https://en.wikipedia.org/wiki/Yoshiyuki_Tomino")
        , ("Yunmen Wenyan", "https://en.wikipedia.org/wiki/Yunmen_Wenyan")
        , ("ZUN", "https://en.wikipedia.org/wiki/Team_Shanghai_Alice#Member")
        , ("Zeo", "/Zeo")
        , ("[Aa]daptive (clinical )?trial", "https://en.wikipedia.org/wiki/Adaptive_clinical_trial")
        , ("[Aa]krasia", "https://en.wikipedia.org/wiki/Akrasia")
        , ("[Aa]pproximate [Bb]ayesian [Cc]omputation", "https://en.wikipedia.org/wiki/Approximate_Bayesian_computation")
        , ("[Aa]rgument from silence", "https://en.wikipedia.org/wiki/Argument_from_silence")
        , ("[Aa]ssassination market", "https://en.wikipedia.org/wiki/Assassination_market")
        , ("[Aa]ssurance [Cc]ontract", "https://en.wikipedia.org/wiki/Assurance_contract")
        , ("[Aa]tomic gardening", "https://en.wikipedia.org/wiki/Atomic_gardening")
        , ("[Aa]vailability heuristic", "https://en.wikipedia.org/wiki/Availability_heuristic")
        , ("[Bb]ack ?prop(agation)?", "https://en.wikipedia.org/wiki/Backpropagation")
        , ("[Bb]ackground selection", "https://en.wikipedia.org/wiki/Background_selection")
        , ("[Bb]ase[ -]rate fallacy", "https://en.wikipedia.org/wiki/Base_rate_fallacy")
        , ("[Bb]atch-?[Nn]orm(alization)?", "https://en.wikipedia.org/wiki/Batch_normalization")
        , ("[Bb]eam[ -]search", "https://en.wikipedia.org/wiki/Beam_search")
        , ("[Bb]eta distribution", "https://en.wikipedia.org/wiki/Beta_distribution")
        , ("[Bb]ias-variance tradeoff", "https://en.wikipedia.org/wiki/Bias-variance_tradeoff")
        , ("[Bb]inary tree", "https://en.wikipedia.org/wiki/Binary_tree")
        , ("[Bb]iobank(ed|s|ing)?", "https://en.wikipedia.org/wiki/Biobank")
        , ("[Bb]irthday paradoxe?s?", "https://en.wikipedia.org/wiki/Birthday_problem")
        , ("Bitcoin.?", "https://en.wikipedia.org/wiki/Bitcoin")
        , ("[Bb]itter [Ll]essons?", "http://www.incompleteideas.net/IncIdeas/BitterLesson.html")
        , ("[Bb]lessings [Oo]f [Ss]cale", "/Scaling-hypothesis#blessings-of-scale")
        , ("[Bb]ody double", "https://en.wikipedia.org/wiki/Political_decoy")
        , ("[Bb]ootstrap(ping|ped)?", "https://en.wikipedia.org/wiki/Bootstrapping_%28statistics%29")
        , ("[Bb]rown adipose tissues?", "https://en.wikipedia.org/wiki/Brown_adipose_tissue")
        , ("[Bb]rown-nosed coatis", "https://en.wikipedia.org/wiki/South_American_coati")
        , ("[Cc]ache-oblivious", "https://en.wikipedia.org/wiki/Cache-oblivious_algorithm")
        , ("[Cc]affein(e|ate|ated)", "https://en.wikipedia.org/wiki/Caffeine")
        , ("[Cc]aloric restriction", "https://en.wikipedia.org/wiki/Caloric_restriction")
        , ("[Cc]ard marking", "https://en.wikipedia.org/wiki/Card_marking")
        , ("[Cc]arfentanil", "https://en.wikipedia.org/wiki/Carfentanil")
        , ("[Cc]ase.?[Cc]ontrol", "https://en.wikipedia.org/wiki/Case%E2%80%93control_study")
        , ("[Cc]eiling effects?", "https://en.wikipedia.org/wiki/Ceiling_effect_(statistics)")
        , ("[Cc]erebral cortexe?s?", "https://en.wikipedia.org/wiki/Cerebral_cortex")
        , ("[Cc]holine", "https://en.wikipedia.org/wiki/Choline")
        , ("[Cc]ognitive [Bb]iase?s?", "https://en.wikipedia.org/wiki/Cognitive_bias")
        , ("[Cc]ommoditize [Yy]our [Cc]omplement", "/Complement")
        , ("[Cc]ommon ?[Cc]rawl", "https://en.wikipedia.org/wiki/Common_Crawl")
        , ("[Cc]omparative advantage", "https://en.wikipedia.org/wiki/Comparative_advantage")
        , ("[Cc]ompressed [Aa]ir [Ee]nergy [Ss]torage", "https://en.wikipedia.org/wiki/Compressed-air_energy_storage")
        , ("[Cc]omputational complexity", "https://en.wikipedia.org/wiki/Computational_complexity_theory")
        , ("[Cc]omputational fluid dynamics?", "https://en.wikipedia.org/wiki/Computational_fluid_dynamics")
        , ("([Cc]onfidence[ -]interval.?|CIs?)", "https://en.wikipedia.org/wiki/Confidence_interval")
        , ("[Cc]onfounding", "https://en.wikipedia.org/wiki/Confounding")
        , ("[Cc]onjunction fallacy", "https://en.wikipedia.org/wiki/Conjunction_fallacy")
        , ("[Cc]onsanguineous marriages?", "https://en.wikipedia.org/wiki/Consanguine_marriage")
        , ("[Cc]onstructed language", "https://en.wikipedia.org/wiki/Constructed_language")
        , ("[Cc]ontrastive", "https://arxiv.org/abs/2010.05113")
        , ("[Cc]owpox", "https://en.wikipedia.org/wiki/Cowpox")
        , ("[Cc]rowdsourcing", "https://en.wikipedia.org/wiki/Crowdsourcing")
        , ("[Cc]ryonics?", "https://en.wikipedia.org/wiki/Cryonics")
        , ("[Cc]ryopreserv(e.?|ation)", "https://en.wikipedia.org/wiki/Cryopreservation")
        , ("[Cc]ryptographic hash function", "https://en.wikipedia.org/wiki/Cryptographic_hash_function")
        , ("[Cc]ypherpunk", "https://en.wikipedia.org/wiki/Cypherpunk")
        , ("[Dd]arcs", "https://en.wikipedia.org/wiki/Darcs")
        , ("[Dd]ark [Tt]riad", "https://en.wikipedia.org/wiki/Dark_triad")
        , ("[Dd]asatinib", "https://en.wikipedia.org/wiki/Dasatinib")
        , ("[Dd]ata URI", "https://en.wikipedia.org/wiki/Data_URI_scheme")
        , ("[Dd]ecision[ -][Tt]heor(y|ies|etc)", "https://en.wikipedia.org/wiki/Decision_theory#Choice_under_uncertainty")
        , ("[Dd]eep brain stimulation", "https://en.wikipedia.org/wiki/Deep_brain_stimulation")
        , ("[Dd]efault [Mm]ode [Nn]etwork", "https://en.wikipedia.org/wiki/Default_mode_network")
        , ("[Dd]eliberate practice", "https://en.wikipedia.org/wiki/Practice_(learning_method)#Deliberate_practice")
        , ("[Dd]emand [Cc]haracteristics?", "https://en.wikipedia.org/wiki/Demand_characteristics")
        , ("[Dd]emographic transition", "https://en.wikipedia.org/wiki/Demographic_transition")
        , ("[Dd]endritic spines?", "https://en.wikipedia.org/wiki/Dendritic_spine")
        , ("[Dd]esigner drug", "https://en.wikipedia.org/wiki/Designer_drug")
        , ("[Dd]ifferentiable", "https://en.wikipedia.org/wiki/Differentiable_function")
        , ("[Dd]igit[ -]span", "https://en.wikipedia.org/wiki/Digit_span")
        , ("[Dd]iminishing returns?", "https://en.wikipedia.org/wiki/Diminishing_returns")
        , ("[Dd]itche?s?", "https://en.wikipedia.org/wiki/Ditch_(fortification)")
        , ("[Dd]ominant [Aa]ssurance [Cc]ontract", "https://en.wikipedia.org/wiki/Assurance_contract#Dominant_assurance_contracts")
        , ("[Dd]opamine", "https://en.wikipedia.org/wiki/Dopamine")
        , ("[Dd]ouble[ -]descent", "https://openai.com/blog/deep-double-descent/")
        , ("[Dd]ouble[ -]spend(ing)?", "https://en.wikipedia.org/wiki/Double-spending")
        , ("[Dd]oujin(shi)?", "https://en.wikipedia.org/wiki/Doujinshi")
        , ("[Dd]ynamic programming", "https://en.wikipedia.org/wiki/Dynamic_programming")
        , ("[Ee]-[Gg]old", "https://en.wikipedia.org/wiki/E-gold")
        , ("[Ee]ffect[ -]sizes?", "https://en.wikipedia.org/wiki/Effect_sizes")
        , ("[Ee]nd[ -][Tt]o[ -][Ee]nd", "/docs/cs/end-to-end-principle/index")
        , ("[Ee]nhanced weathering", "https://en.wikipedia.org/wiki/Enhanced_weathering")
        , ("[Ee]pistasis", "https://en.wikipedia.org/wiki/Epistasis")
        , ("[Ee]verything [Ii]s [Cc]orrelated", "/Everything")
        , ("[Ee]xenatide", "https://en.wikipedia.org/wiki/Exenatide")
        , ("[Ee]xperience curves?", "https://en.wikipedia.org/wiki/Experience_curve_effects")
        , ("[Ee]xponential distribution", "https://en.wikipedia.org/wiki/Exponential_distribution")
        , ("[Ff]actor analysis", "https://en.wikipedia.org/wiki/Factor_analysis")
        , ("[Bb]i-?factor ?(model|models|modeling|analysis)?", "/docs/statistics/2019-markon.pdf")
        , ("[Ff]entanyl", "https://en.wikipedia.org/wiki/Fentanyl")
        , ("[Ff]ixation", "https://en.wikipedia.org/wiki/Fixation_%28population_genetics%29")
        , ("[Ff]ixing effect", "https://en.wikipedia.org/wiki/Functional_fixedness")
        , ("[Ff]lehmen response", "https://en.wikipedia.org/wiki/Flehmen_response")
        , ("[Ff]urry", "https://en.wikipedia.org/wiki/Furry_fandom")
        , ("[Gg]alantamine", "https://en.wikipedia.org/wiki/Galantamine")
        , ("[Gg]ame theory", "https://en.wikipedia.org/wiki/Game_theory")
        , ("[Gg]enetic [Cc]orrelations?", "https://en.wikipedia.org/wiki/Genetic_correlation")
        , ("[Gg]enetic drift", "https://en.wikipedia.org/wiki/Genetic_drift")
        , ("[Gg]enome-[Ww]ide [Cc]omplex [Tt]rait [Aa]nalysis", "https://en.wikipedia.org/w/index.php?title=Genome-wide_complex_trait_analysis&oldid=871165308")
        , ("[Gg]esamtkunstwerk", "https://en.wikipedia.org/wiki/Gesamtkunstwerk")
        , ("[Gg]gambler's ruin", "https://en.wikipedia.org/wiki/Gambler%27s_ruin")
        , ("[Gg]it", "https://en.wikipedia.org/wiki/Git_%28software%29")
        , ("[Gg]lucagon", "https://en.wikipedia.org/wiki/Glucagon")
        , ("[Hg]awala", "https://en.wikipedia.org/wiki/Hawala")
        , ("[Hh]angul", "https://en.wikipedia.org/wiki/Hangul")
        , ("[Hh]eavy water", "https://en.wikipedia.org/wiki/Heavy_water")
        , ("[Hh]eterozygo(sity|us)", "https://en.wikipedia.org/wiki/Zygosity#Heterozygous")
        , ("[Hh]idden-variable theor(y|ies)", "https://en.wikipedia.org/wiki/Hidden-variable_theory")
        , ("[Hh]igh jumping", "https://en.wikipedia.org/wiki/High_jump")
        , ("[Hh]ikikomori", "https://en.wikipedia.org/wiki/Hikikomori")
        , ("[Hh]indsight bias", "https://en.wikipedia.org/wiki/Hindsight_bias")
        , ("[Hh]oly [Ww]ars?", "http://www.catb.org/jargon/html/H/holy-wars.html")
        , ("[Hh]omomorphic encryption", "https://en.wikipedia.org/wiki/Homomorphic_encryption")
        , ("[Hh]omozygo(sity|us)", "https://en.wikipedia.org/wiki/Zygosity#Homozygous")
        , ("[Hh]uperzine-A", "https://en.wikipedia.org/wiki/Huperzine-A")
        , ("[Hh]yalin", "https://en.wikipedia.org/wiki/Hyalin")
        , ("[Hh]ybridization", "https://en.wikipedia.org/wiki/Hybrid_(biology)")
        , ("[Hh]ydrocephalus", "https://en.wikipedia.org/wiki/Hydrocephalus")
        , ("[Hh]yper ?[Nn]etworks", "https://arxiv.org/abs/1609.09106#google")
        , ("[Hh]yperbolic discounting", "https://en.wikipedia.org/wiki/Hyperbolic_discounting")
        , ("[Ii]diopathic hypersomnia", "https://en.wikipedia.org/wiki/Idiopathic_hypersomnia")
        , ("[Ii]nclusionists?", "https://meta.wikimedia.org/wiki/Inclusionism")
        , ("[Jj]ello", "https://en.wikipedia.org/wiki/Gelatin_dessert")
        , ("[Jj]umping [Ss]piders?", "https://en.wikipedia.org/wiki/Jumping_spider")
        , ("[Jj]ustified text", "https://en.wikipedia.org/wiki/Typographic_alignment#Justified")
        , ("[Kk]amikaze", "https://en.wikipedia.org/wiki/Kamikaze")
        , ("[Kk]ratom", "https://en.wikipedia.org/wiki/Kratom")
        , ("[Ll]atent", "https://en.wikipedia.org/wiki/Latent_variable")
        , ("[Ll]avaan", "https://lavaan.ugent.be/")
        , ("[Ll]azy evaluation", "https://en.wikipedia.org/wiki/Lazy_evaluation")
        , ("[Ll]evamisole", "https://en.wikipedia.org/wiki/Levamisole")
        , ("[Ll]iability[ -]threshold", "https://en.wikipedia.org/wiki/Liability-threshold_model")
        , ("[Ll]inear[ -][Pp]rogramming", "https://en.wikipedia.org/wiki/Linear_programming")
        , ("[Ll]ipofuscin", "https://en.wikipedia.org/wiki/Lipofuscin")
        , ("[Ll]iraglutide", "https://en.wikipedia.org/wiki/Liraglutide")
        , ("[Ll]ithium", "https://en.wikipedia.org/wiki/Lithium")
        , ("[Ll]lithium [Oo]rotate", "https://en.wikipedia.org/wiki/Lithium_orotate")
        , ("[Ll]ocus [Cc]oeruleus", "https://en.wikipedia.org/wiki/Locus_coeruleus")
        , ("[Ll]ogistic regression", "https://en.wikipedia.org/wiki/Logistic_regression")
        , ("[Ll]oss functions?", "https://en.wikipedia.org/wiki/Loss_function")
        , ("[Ll]ucid dream(s|ing|er)", "https://en.wikipedia.org/wiki/Lucid_dream")
        , ("[Ll]ucid dreaming", "https://en.wikipedia.org/wiki/Lucid_dreaming")
        , ("[Mm]aximum [Ll]ikelihood", "https://en.wikipedia.org/wiki/Maximum_likelihood_estimation")
        , ("[Mm]easurement[ -]error", "https://en.wikipedia.org/wiki/Measurement_error")
        , ("[Mm]emoization", "https://en.wikipedia.org/wiki/Memoization")
        , ("[Mm]escaline", "https://en.wikipedia.org/wiki/Mescaline")
        , ("[Mm]eta [Pp]seudo [Ll]abels", "https://arxiv.org/abs/2003.10580#google")
        , ("[Mm]eta[ -]analy(sis|ses|tic)", "https://en.wikipedia.org/wiki/Meta-analysis")
        , ("[Mm]etformin", "https://en.wikipedia.org/wiki/Metformin")
        , ("[Mm]icrobio(me|ta).?", "https://en.wikipedia.org/wiki/Microbiome")
        , ("[Mm]ixed [Ii]nteger [Pp]rogramming", "https://en.wikipedia.org/wiki/Linear_programming#Integer_unknowns")
        , ("[Mm]ixture [Mm]odel(s|ing)?", "https://en.wikipedia.org/wiki/Mixture_model")
        , ("[Mm]odal [Rr]ealism", "https://en.wikipedia.org/wiki/Modal_realism")
        , ("[Mm]ono no aware", "https://en.wikipedia.org/wiki/Mono_no_aware")
        , ("[Mm]ultiple comparisons?", "https://en.wikipedia.org/wiki/Multiple_comparisons_problem")
        , ("[Mm]ultiple discover(y|ies)", "https://en.wikipedia.org/wiki/Multiple_discovery")
        , ("([Gg]enerali([zs]ed)? [Ll]inear [Mm]odels?|GLMs?)", "https://en.wikipedia.org/wiki/Generalized_linear_model")
        , ("[Mm]ultivariate linear model", "https://en.wikipedia.org/wiki/Multivariate_linear_model")
        , ("[Mm]utation load", "https://en.wikipedia.org/wiki/Mutation_load")
        , ("[Mm]yxoma virus", "https://en.wikipedia.org/wiki/Myxoma_virus")
        , ("[Nn]-grams?", "https://en.wikipedia.org/wiki/N-grams")
        , ("[Nn][- ]?body problems?", "https://en.wikipedia.org/wiki/N-body_problem")
        , ("[Nn]atural experiment", "https://en.wikipedia.org/wiki/Natural_experiment")
        , ("[Nn]atural selection", "https://en.wikipedia.org/wiki/Natural_selection")
        , ("[Nn]egative externalit(y|ies)", "https://en.wikipedia.org/wiki/Negative_externality")
        , ("[Nn]icotine", "/Nicotine")
        , ("([Ee]lectronic [Cc]igarette|[Ee]-[Cc]igarette|[Vv]ap(ing|e))", "https://en.wikipedia.org/wiki/Electronic_cigarette")
        , ("[Nn]oble lie", "https://en.wikipedia.org/wiki/Noble_lie")
        , ("[Nn]ootropics?", "https://en.wikipedia.org/wiki/Nootropics")
        , ("[Nn]ucleus [Ss]ampling", "https://arxiv.org/abs/1904.09751#allen")
        , ("[Oo]ld-style numerals?", "https://en.wikipedia.org/wiki/Text_figures")
        , ("[Oo]perant conditioning", "https://en.wikipedia.org/wiki/Operant_conditioning")
        , ("[Oo]pioids?", "https://en.wikipedia.org/wiki/Opioid")
        , ("[Oo]ptimal stopping", "https://en.wikipedia.org/wiki/Optimal_stopping")
        , ("[Oo]ptogenetics?", "https://en.wikipedia.org/wiki/Optogenetics")
        , ("[Oo]rphan [Ww]ork", "https://en.wikipedia.org/wiki/Orphan_work")
        , ("[Oo]taku", "https://en.wikipedia.org/wiki/Otaku")
        , ("[Oo]utside [Vv]iew", "https://www.lesswrong.com/tag/inside-outside-view")
        , ("[Op]perations research", "https://en.wikipedia.org/wiki/Operations_research")
        , ("[Op]pportunity cost", "https://en.wikipedia.org/wiki/Opportunity_cost")
        , ("[Pp]aracosm", "https://en.wikipedia.org/wiki/Paracosm")
        , ("[Pp]arasocial", "/notes/Parasocial")
        , ("[Pp]areidolia", "https://en.wikipedia.org/wiki/Pareidolia")
        , ("[Pp]article filtering", "https://en.wikipedia.org/wiki/Particle_filter")
        , ("[Pp]entobarbital", "https://en.wikipedia.org/wiki/Pentobarbital")
        , ("[Pp]erpetual futures", "https://en.wikipedia.org/wiki/Perpetual_futures")
        , ("[Pp]harmacogenomics", "https://en.wikipedia.org/wiki/Pharmacogenomics")
        , ("[Pp]hotoplethysmography", "https://en.wikipedia.org/wiki/Photoplethysmogram")
        , ("[Pp]iracetam", "https://en.wikipedia.org/wiki/Piracetam")
        , ("[Pp]olyphasic sleep", "https://en.wikipedia.org/wiki/Polyphasic_sleep")
        , ("[Pp]opulation genetics?", "https://en.wikipedia.org/wiki/Population_genetics")
        , ("[Pp]ositional good", "https://en.wikipedia.org/wiki/Positional_good")
        , ("[Pp]ower[ -]law", "https://en.wikipedia.org/wiki/Power_law")
        , ("[Pp]rediction [Mm]arket.?", "/Prediction-markets")
        , ("[Pp]rediction markets?", "https://en.wikipedia.org/wiki/Prediction_markets")
        , ("[Pp]redictron", "https://arxiv.org/abs/1612.08810#deepmind")
        , ("[Pp]rice discrimination", "https://en.wikipedia.org/wiki/Price_discrimination")
        , ("[Pp]riming", "https://en.wikipedia.org/wiki/Priming_(psychology)")
        , ("[Pp]rincipal-agent problems?", "https://en.wikipedia.org/wiki/Principal-agent_problems")
        , ("([Pp]riors|[Pp]rior probabil(y|ies)|[Pp]rior distributions?)", "https://en.wikipedia.org/wiki/Prior_probability")
        , ("[Pp]silocybin", "https://en.wikipedia.org/wiki/Psilocybin")
        , ("[Pp]sychopath(y|ic|s)?", "https://en.wikipedia.org/wiki/Psychopathy")
        , ("[Pp]ublic [Dd]omain", "https://en.wikipedia.org/wiki/Public_domain")
        , ("[Pp]ublic[ -]key cryptography", "https://en.wikipedia.org/wiki/Public-key_cryptography")
        , ("[Pp]unctuated equilibriums?", "https://en.wikipedia.org/wiki/Punctuated_equilibrium")
        , ("[Qq]-learning", "https://en.wikipedia.org/wiki/Q-learning")
        , ("[Rr]adium", "https://en.wikipedia.org/wiki/Radium")
        , ("[Rr]amjet", "https://en.wikipedia.org/wiki/Ramjet")
        , ("[Rr]andom [Ff]orests?", "https://en.wikipedia.org/wiki/Random_forest")
        , ("[Rr]ecognition memory", "https://en.wikipedia.org/wiki/Recognition_memory")
        , ("[Rr]ecombination", "https://en.wikipedia.org/wiki/Genetic_recombination")
        , ("[Rr]ectified Gaussian", "https://en.wikipedia.org/wiki/Rectified_Gaussian_distribution")
        , ("[Rr]egression (to|toward) the mean", "https://en.wikipedia.org/wiki/Regression_to_the_mean")
        , ("[Rr]egression [Dd]iscontinuity", "https://en.wikipedia.org/wiki/Regression_discontinuity_design")
        , ("[Rr]einforcement [Ll]earning", "https://en.wikipedia.org/wiki/Reinforcement_learning")
        , ("[Rr]evealed preference.?", "https://en.wikipedia.org/wiki/Revealed_preference")
        , ("[Rr]everse causation", "https://en.wikipedia.org/wiki/Correlation_does_not_imply_causation#B_causes_A_(reverse_causation_or_reverse_causality)")
        , ("[Rr]ice futures market", "https://en.wikipedia.org/wiki/D%C5%8Djima_Rice_Exchange")
        , ("[Rr]obots\\.txt", "https://en.wikipedia.org/wiki/Robots_exclusion_standard")
        , ("[Rr]sync", "https://en.wikipedia.org/wiki/Rsync")
        , ("[Rr]ule of succession", "https://en.wikipedia.org/wiki/Rule_of_succession")
        , ("[Ss]adis(m|tic|t|ts)", "https://en.wikipedia.org/wiki/Sadistic_personality_disorder")
        , ("[Ss]caling [Hh]ypothesis", "/Scaling-hypothesis")
        , ("[Ss]caling [Ll]aws?", "/notes/Scaling")
        , ("[Ss]chizoid", "https://en.wikipedia.org/wiki/Schizoid_personality_disorder")
        , ("[Ss]chizotyp(y|ical)", "https://en.wikipedia.org/wiki/Schizotypy")
        , ("[Ss]ecurity[ -]through[ -]obscurity", "https://en.wikipedia.org/wiki/Security_through_obscurity")
        , ("[Ss]elegiline", "https://en.wikipedia.org/wiki/Selegiline")
        , ("[Ss]emaglutide", "https://en.wikipedia.org/wiki/Semaglutide")
        , ("([Cc]ell(ular)?[Ss]enescen(ce|t).?|[Ss]enescen(ce|t).?)", "https://en.wikipedia.org/wiki/Cellular_senescence")
        , ("[Ss]enolytics?", "https://en.wikipedia.org/wiki/Senolytic")
        , ("[Ss]equential analysis", "https://en.wikipedia.org/wiki/Sequential_analysis")
        , ("[Ss]exual selection", "https://en.wikipedia.org/wiki/Sexual_selection")
        , ("[Ss]peedrunning", "https://en.wikipedia.org/wiki/Speedrun")
        , ("[Ss]um of normally distributed random variables", "https://en.wikipedia.org/wiki/Sum_of_normally_distributed_random_variables")
        , ("[Ss]uperflat", "https://en.wikipedia.org/wiki/Superflat")
        , ("[Ss]uperpressure balloons?", "https://en.wikipedia.org/wiki/Superpressure_balloon")
        , ("[Ss]urvival analysis", "https://en.wikipedia.org/wiki/Survival_analysis")
        , ("[Ss]urvivorship curve", "https://en.wikipedia.org/wiki/Survivorship_curve")
        , ("[Tt]ime[ -]preference", "https://en.wikipedia.org/wiki/Time_preference")
        , ("[Tt]okusatsu", "https://en.wikipedia.org/wiki/Tokusatsu")
        , ("[Tt]orsion balance", "https://en.wikipedia.org/wiki/Torsion_spring#Torsion_balance")
        , ("[Tt]ragedy of the anticommons", "https://en.wikipedia.org/wiki/Tragedy_of_the_anticommons")
        , ("[Tt]ransfer RNAs?", "https://en.wikipedia.org/wiki/Transfer_RNA")
        , ("[Tt]ree induction", "https://en.wikipedia.org/wiki/Decision_tree_learning")
        , ("[Tt]rophic level", "https://en.wikipedia.org/wiki/Trophic_level")
        , ("[Tt]runcation selection", "https://en.wikipedia.org/wiki/Truncation_selection")
        , ("[Vv]alue [Ii]teration [Nn]etworks?", "https://arxiv.org/abs/1602.02867#deepmind")
        , ("[Vv]alue-[Ee]quivalence", "https://arxiv.org/abs/2011.03506#deepmind")
        , ("[Vv]ariance", "https://en.wikipedia.org/wiki/Variance")
        , ("[Vv]ariance[ -][Cc]omponent.?", "/notes/Variance-components")
        , ("[Vv]itri(fied|fy|fying|fication)", "https://en.wikipedia.org/wiki/Vitrification")
        , ("[Ww]abi[ -]sabi", "https://en.wikipedia.org/wiki/Wabi-sabi")
        , ("[Ww]ake therapy", "https://en.wikipedia.org/wiki/Wake_therapy")
        , ("[Ww]get", "https://en.wikipedia.org/wiki/Wget")
        , ("[Ww]inner's curse", "https://en.wikipedia.org/wiki/Winner%27s_curse")
        , ("[Ww]orse[ -][Ii]s[ -][Bb]etter", "https://en.wikipedia.org/wiki/Worse_is_better")
        , ("[cC]onscientiousness", "https://en.wikipedia.org/wiki/Conscientiousness#Personality_models")
        , ("[pP]roper scoring rule", "https://en.wikipedia.org/wiki/Proper_scoring_rule")
        , ("[rR]epeated measures", "https://en.wikipedia.org/wiki/Repeated_measures_design")
        , ("[tT]acit knowledge", "https://en.wikipedia.org/wiki/Tacit_knowledge")
        , ("\\/r\\/DecisionTheory", "https://old.reddit.com/r/DecisionTheory/")
        , ("[aA]dditive regression models", "https://en.wikipedia.org/wiki/Generalized_additive_model")
        , ("[aA]rbtt", "https://arbtt.nomeata.de/")
        , ("brms", "https://github.com/paul-buerkner/brms")
        , ("[Cc]itronellol", "https://en.wikipedia.org/wiki/Citronellol")
        , ("[Dd]el\\.icio\\.us", "https://en.wikipedia.org/wiki/Delicious_(website)")
        , ("[Dd]rop-?caps?", "https://en.wikipedia.org/wiki/Initial")
        , ("[Ee]ntorhinal-hippocampal", "https://en.wikipedia.org/wiki/EC-hippocampus_system")
        , ("gMLP", "https://arxiv.org/abs/2105.08050#google")
        , ("[Gg]scan2pdf", "http://gscan2pdf.sourceforge.net/")
        , ("iGPT", "https://openai.com/blog/image-gpt/")
        , ("[Ii]nbreeding[ -]depression", "https://en.wikipedia.org/wiki/Inbreeding_depression")
        , ("lbpcascade_animeface", "https://github.com/nagadomi/lbpcascade_animeface")
        , ("[Ll]inkchecker", "https://github.com/linkchecker/linkchecker")
        , ("mRNAs?", "https://en.wikipedia.org/wiki/Messenger_RNA")
        , ("mT5", "https://arxiv.org/abs/2010.11934#google")
        , ("mathjax-node-page", "https://github.com/pkra/mathjax-node-page/")
        , ("[Oo]crmypdf", "https://github.com/ocrmypdf/OCRmyPDF")
        , ("[Ss]hort[- ]?s(ale|elling)", "https://en.wikipedia.org/wiki/Short_(finance)")
        , ("[Ss]ocial[- ]engineering", "https://en.wikipedia.org/wiki/Social_engineering_(security)")
        , ("[Ss]tyle[- ]transfers?", "https://arxiv.org/abs/1508.06576") -- style transfer, Gatys et al 2015
        , ("t-SNE", "https://en.wikipedia.org/wiki/T-distributed_stochastic_neighbor_embedding")
        , ("t-distribution", "https://en.wikipedia.org/wiki/Student%27s_t-distribution")
        , ("textgenrnn", "https://github.com/minimaxir/textgenrnn")
        , ("torch-rnn", "https://github.com/jcjohnson/torch-rnn")
        , ("uBlock [Oo]rigin", "https://github.com/gorhill/uBlock")
        , ("waifu2x", "https://github.com/nagadomi/waifu2x")
        , ("wav2vec 2\\.0", "https://arxiv.org/abs/2006.11477#facebook")
        , ("[Rr]ent[ -]seeking", "https://en.wikipedia.org/wiki/Rent-seeking")
        , ("[Pp]ublic[ -]choice( theory)?", "https://en.wikipedia.org/wiki/Public_choice")
        , ("(C.? [Ee]legans|Caenorhabditis elegans)", "https://en.wikipedia.org/wiki/Caenorhabditis_elegans")
        , ("(([Dd]is)[Aa]ssortative [Mm]ating|[Aa]ssortativ(e|ity)|[Aa]ssortative [Mm]atching)", "https://en.wikipedia.org/wiki/Assortative_mating")
        , ("(SES|[Ss]ocio.?economic [Ss]tatus)", "https://en.wikipedia.org/wiki/Socioeconomic_status")
        , ("([Ee]xecutive [Ff]unction(.|ing)?|EFs?)", "https://en.wikipedia.org/wiki/Executive_functions")
        , ("(Rich Sutton|Rich S. Sutton|Richard S. Sutton|Richard Sutton|Sutton)", "https://en.wikipedia.org/wiki/Richard_S._Sutton")
        , ("[Oo]bject.detection", "https://en.wikipedia.org/wiki/Object_detection")
        , ("([Aa]utomated|[Ii]mage|[Pp]anoptic|[Pp]ixel|[S]emantic) segmentation", "https://en.wikipedia.org/wiki/Image_segmentation")
        , ("[Bb]ounding.box.?.?", "https://en.wikipedia.org/wiki/Minimum_bounding_box")
        , ("[Pp]ropensity[ -][Ss]core(s|[ -][Mm]atching|analysis|model|methods?)?", "https://en.wikipedia.org/wiki/Propensity_score_matching")
        , ("([Cc]atnip|[Nn]epeta [cc]ataria|[Cc]at nip|[Cc]atmint)", "https://en.wikipedia.org/wiki/Catnip")
        , ("([Vv]alerian|Valeriana officinalis)", "https://en.wikipedia.org/wiki/Valerian_(herb)")
        , ("([Ss]ilver[ -]vine|Actinidia polygama|[Mm]atatabi)", "https://en.wikipedia.org/wiki/Actinidia_polygama")
        , ("(Tatarian honeysuckle|[Hh]oneysuckle|Lonicera tatarica)", "https://en.wikipedia.org/wiki/Lonicera_tatarica")
        , ("([a-zA-Z1-9.,]+-)?[Nn]epetalactone.?", "https://en.wikipedia.org/wiki/Nepetalactone")
        , ("[Aa]ctinidine", "https://en.wikipedia.org/wiki/Actinidine")
        , ("(Gibbs sampl(er|ing)|Gibbs (learning )?algorithm.?)", "https://en.wikipedia.org/wiki/Gibbs_sampling")
        , ("(Felis catus|[Dd]omestic(ed)? cat.?|[Cc]ats?)", "https://en.wikipedia.org/wiki/Cat")
        , ("(Drosophila melanogaster|D. [Mm]elanogaster|[Dd]rosophila)", "https://en.wikipedia.org/wiki/Drosophila_melanogaster")
        , ("[Cc]ross[ -]entropy", "https://en.wikipedia.org/wiki/Cross_entropy")
        , ("[Ee]ntropy", "https://en.wikipedia.org/wiki/Entropy_(information_theory)") -- doesn't look like most of my uses are physics but information theory
        , ("(([Rr]andomi[zs]ed )?[Cc]ontrol(led)? ((clinical[ -])?[Tt]rials?|[Ee]xperiment)|RCTs?)", "https://en.wikipedia.org/wiki/Randomized_controlled_trial")
        , ("(GPU|[Gg]raphics [Pp]rocessing [Uu]nit)", "https://en.wikipedia.org/wiki/Graphics_processing_unit")
        , ("(F<sub>st</sub>|F~st~|Fst)", "https://en.wikipedia.org/wiki/Fixation_index")
        , ("LaMDA", "https://blog.google/technology/ai/lamda/")
        , ("[Aa](llometric growth|llometric scaling|llometry)", "https://en.wikipedia.org/wiki/Allometry")
        , ("[Pp]edigree", "https://en.wikipedia.org/wiki/Pedigree_chart")
        , ("(N,N-dimethyltryptamine|N,N-DMT|DMT)", "https://en.wikipedia.org/wiki/N,N-Dimethyltryptamine")
        , ("(MNIST|MNIST dataset|MNIST digit)", "https://en.wikipedia.org/wiki/MNIST_database")
        , ("([Hh]idden [Mm]arkov [Mm]odel.?|[Hh]idden [Mm]arkov|HMM.?)", "https://en.wikipedia.org/wiki/Hidden_Markov_model")
        , ("[Dd]ata[ -][Aa]ugment(ation.?)?", "https://en.wikipedia.org/wiki/Data_augmentation")
        , ("(JFT-300[Mm]?|JFT)", "https://arxiv.org/abs/1707.02968#google")
        , ("JFT-3[Bb]", "https://arxiv.org/abs/2106.04560#google")
        , ("([Mm]ethylphenidate|Ritalin|Concerta)", "https://en.wikipedia.org/wiki/Methylphenidate")
        , ("([Aa]utism [Ss]pectrum|[Aa]utism [Ss]pectrum [Dd]isorders?|ASD)", "https://en.wikipedia.org/wiki/Autism_spectrum")
        , ("(GSS|General Social Survey)", "https://en.wikipedia.org/wiki/General_Social_Survey")
        , ("([Hh]aplotypes?)", "https://en.wikipedia.org/wiki/Haplotype")
        , ("[Ss]ummary [Ss]tatistics?", "https://en.wikipedia.org/wiki/Summary_statistics")
        , ("[Pp]enetrance", "https://en.wikipedia.org/wiki/Penetrance")
        , ("OLS( regressions?|regression models?)?", "https://en.wikipedia.org/wiki/Ordinary_least_squares")
        , ("[Ee]nsemble?s( learning| methods?)", "https://en.wikipedia.org/wiki/Ensemble_learning")
        , ("fMRIs?( machine| study| experiment| data| task| responses)", "https://en.wikipedia.org/wiki/Functional_magnetic_resonance_imaging")
        , ("MuJoCo", "https://mujoco.org/")
        , ("VQGAN", "https://compvis.github.io/taming-transformers/")
        ]
