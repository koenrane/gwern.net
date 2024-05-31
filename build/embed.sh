#!/bin/bash

# similar.sh: get a neural net summary (embedding) of a text string (usually an annotation)
# Author: Gwern Branwen
# Date: 2021-12-05
# When:  Time-stamp: "2024-05-31 16:00:07 gwern"
# License: CC-0
#
# Shell script to pass a document into the OpenAI API Embedding endpoint ( https://beta.openai.com/docs/api-reference/embeddings
# https://openai.com/blog/introducing-text-and-code-embeddings/ https://arxiv.org/abs/2201.10005#openai
# https://beta.openai.com/docs/guides/embeddings/use-cases ). Authentication via shell environment variable.
#
# Example:
#
# $ embed.sh "foo bar"
# # text-embedding-ada-002-v2
# # [
# #   -0.016606577,
# #   -0.015486566,
# #   -0.01253444,
# #   -0.022013048,
# #   -0.013647537,
# #   0.0068652504,
# #   ... ]
#
# Because an embedding is unique to each model, and embeddings generated by different models can't
# be easily compared, it is important to track the model+version that generated it. Separated by a
# newline, a JSON array of 1024–12288 floats (depending on model size; bigger = more = better)
# follows and is the actual embedding.
#
# The OA API previously provided a semantic Search endpoint
# <https://beta.openai.com/docs/guides/search> which supports up to 2GB of text file inputs, and
# will take short inputs ("One limitation to keep in mind is that the query and longest document
# must be below 2000 tokens together.") to return the <=200 most 'similar' results. This could be
# used to implement similar-links, but the drawback is that inputs would need to be much shorter,
# the set of searched documents would have to be constantly re-uploaded to include new documents,
# and it would not support any additional functionality. Using embeddings + vector-search allows for
# using the full 2048 BPE context window, allows updating the vector-search database locally without
# touching the OA API, and enables downstream tasks like feeding the embeddings into a classifier
# for tagging. (Tagging could itself be done using the Classification endpoint
# <https://beta.openai.com/docs/guides/classifications> but with caveats of its own, and further
# expense.) While the Search endpoint would be a good starting point, particularly for prototyping,
# using Embedding is probably better in the long run.
#
# Requires: curl, jq, valid API key defined in `$OPENAI_API_KEY`

# set -e
set -x

# Input: X BPEs of text
# Output: https://beta.openai.com/docs/guides/embeddings/types-of-embedding-models
# 'text-embedding-3' models can be truncated to smaller dimensions which retain most performance, using a `dimension` argument.
# <https://openai.com/index/new-embedding-models-and-api-updates/> <https://platform.openai.com/docs/guides/embeddings/use-cases>

ENGINE="text-embedding-3-large"
ENGINE_DIMENSION="256"
TEXT="$*"
if [ "${#TEXT}" == 0 ]; then TEXT=$(</dev/stdin); fi
TEXT_LENGTH="${#TEXT}"
TRUNCATED=0

while [ $TEXT_LENGTH -gt 0 ]; do

    RESULT="$(curl --silent "https://api.openai.com/v1/engines/$ENGINE/embeddings" -H "Content-Type: application/json" -H "Authorization: Bearer $OPENAI_API_KEY" \
         -d "{\"input\": \"$TEXT\", \"dimensions\": $ENGINE_DIMENSION}")"
    PARSED="$(echo "$RESULT" | jq --raw-output '.model, .data[0].embedding')"

    if [ "$(echo "$PARSED" | grep -F 'exceeded your current quota' | wc --char)" != 0 ]; then
        echo "Quota exceeded!" >> /dev/stderr
        echo "$RESULT" >> /dev/stderr
        exit 1
    else
        if [ "$PARSED" = "null
null" ] && [ $(( TRUNCATED < 500 )) ]; then
            echo "Length error? $TEXT_LENGTH $(echo "$RESULT" | jq .)" 1>&2
            # drop _n_ characters to try again
            TEXT_LENGTH="$(( TEXT_LENGTH - 100 ))"
            TRUNCATED=$(( TRUNCATED + 100 ))
            TEXT="${TEXT:0:$TEXT_LENGTH}"
            sleep 1s
        else
            echo "$PARSED"
            break
        fi
    fi
done

# Example output:
#  $ curl --silent 'https://api.openai.com/v1/engines/text-embedding-ada-002/embeddings' -H "Content-Type: application/json" -H "Authorization: Bearer $OPENAI_API_KEY" -d '{"input": "Sample document text goes here"}' | jq --raw-output '.model, .data[0].embedding'
# text-embedding-ada-002-v2
# [
#   -0.0030407698,
#   0.011684642,
#   -0.005026957,
#   -0.02723721,
#   -0.016361194,
#   0.03234503,
#   -0.016159039,
#   -0.001036894,
#   -0.025822116,
#   -0.0066677933,
#   0.020148259,
#   0.016657691,
#   -0.009164426,
#   0.023423193,
#   -0.010121299,
#   0.013443403,
#   0.025229124,
#   -0.016873324,
#   0.01211591,
#   -0.016361194,
#   -0.00426887,
#   -0.0065026986,
#   -0.0043699485,
#   0.020808637,
#   -0.010539089,
#   -0.003652293,
#   0.013692729,
#   -0.0263612,
#   -0.00031713292,
#   -0.002218667,
#   0.0058221053,
#   -0.0100876065,
#   -0.02822104,
#   -0.016159039,
#   -0.004218331,
#   0.007466311,
#   -0.0029228453,
#   -0.031455543,
#   0.023881415,
#   -0.033288427,
#   -0.0003649345,
#   0.013072783,
#   0.0070754755,
#   -0.005680596,
#   0.0031064707,
#   -0.029811336,
#   0.026293814,
#   -0.0046428596,
#   0.0066071465,
#   0.01749327,
#   0.027331552,
#   0.01578168,
#   -0.022196777,
#   0.0028537752,
#   -0.006489222,
#   0.0063915127,
#   -0.016981142,
#   0.020067396,
#   0.0034838293,
#   -0.0035074141,
#   -0.0010613214,
#   0.003578169,
#   -0.0026583571,
#   -0.012473052,
#   -0.018072786,
#   -0.035202175,
#   -0.031725083,
#   0.007574128,
#   0.0070619984,
#   0.005582887,
#   0.020673865,
#   0.011010787,
#   -0.011590303,
#   -0.017385453,
#   0.006654316,
#   0.010181946,
#   -0.012075478,
#   -0.012419144,
#   0.00027564872,
#   -0.001097541,
#   0.004612536,
#   -0.026603788,
#   -0.0023787075,
#   0.032048535,
#   0.009076824,
#   0.014083565,
#   0.018261464,
#   0.029029666,
#   -0.021078179,
#   -0.017277637,
#   -0.0059602456,
#   0.01582211,
#   -0.004326148,
#   0.016994618,
#   -0.013234508,
#   0.022008099,
#   -0.0053807306,
#   0.024339635,
#   0.0037938026,
#   -0.04102428,
#   0.008456877,
#   0.00988545,
#   -0.012109171,
#   -0.01025607,
#   -0.03935312,
#   0.0057109194,
#   0.016226424,
#   -0.014824806,
#   0.016091652,
#   0.014407015,
#   -0.021401629,
#   0.012628039,
#   -0.0045417813,
#   -0.033261474,
#   0.014218336,
#   0.004636121,
#   -0.0044238567,
#   -0.021927236,
#   0.0011666111,
#   -0.005215636,
#   -0.013308632,
#   0.026091658,
#   0.04000002,
#   -0.016442057,
#   0.014029657,
#   0.023679258,
#   -0.005117927,
#   -0.031859856,
#   0.012769548,
#   -0.005963615,
#   0.01809974,
#   0.042479806,
#   0.024258774,
#   0.020552572,
#   -0.028247993,
#   0.01880055,
#   -0.045417815,
#   0.019137476,
#   -0.021832896,
#   -0.017479794,
#   0.008921837,
#   0.034932632,
#   -0.0062028333,
#   -0.006270219,
#   0.0068564727,
#   0.011192728,
#   0.00068901654,
#   -0.021051224,
#   0.0108625395,
#   -0.013840978,
#   0.010849062,
#   0.0024241926,
#   -0.007082214,
#   0.01202157,
#   0.003679247,
#   0.026239906,
#   0.012432621,
#   -0.0038712958,
#   -0.0113274995,
#   -0.020525618,
#   0.00811995,
#   0.01452831,
#   0.01939354,
#   -0.010040437,
#   0.010424534,
#   0.041374683,
#   0.0026566726,
#   -0.010761461,
#   0.0003617758,
#   -0.017628042,
#   -0.024474407,
#   0.01694071,
#   -0.045687355,
#   0.004164423,
#   -0.03309975,
#   0.024622655,
#   0.014932622,
#   0.014986531,
#   -0.009076824,
#   -0.023167128,
#   -0.019784378,
#   0.008018872,
#   0.01183289,
#   0.037250694,
#   -0.036549885,
#   -0.0036826164,
#   -0.015606477,
#   0.00048854476,
#   0.0026330876,
#   0.0006751183,
#   0.008018872,
#   0.010417795,
#   0.004989895,
#   -0.02353101,
#   -0.69088984,
#   -0.021199472,
#   -0.0037466327,
#   -0.011731812,
#   0.025714299,
#   0.020660387,
#   0.0117115965,
#   0.010168469,
#   -0.010404319,
#   0.014137474,
#   -0.023140173,
#   0.0053436686,
#   -0.0109366635,
#   -0.0029683304,
#   -0.017574133,
#   -0.018921843,
#   0.0001869947,
#   0.0037803254,
#   -0.01916443,
#   0.007863886,
#   0.00020205115,
#   0.013497312,
#   -0.028975757,
#   0.013753377,
#   0.012493268,
#   -0.00086253416,
#   0.0049865255,
#   -0.016442057,
#   0.0029110527,
#   0.024326159,
#   -0.03749328,
#   -0.011111866,
#   -0.0050707576,
#   0.022466319,
#   0.053800568,
#   -0.00015077501,
#   -0.00010065706,
#   -0.0073315403,
#   0.011307283,
#   0.013221031,
#   -0.018315373,
#   -0.017466316,
#   0.006095017,
#   -0.01591645,
#   -0.0014260452,
#   0.0016214631,
#   0.029946107,
#   0.011617256,
#   0.017722381,
#   0.027264165,
#   -0.00556941,
#   0.0010242593,
#   0.015552569,
#   -0.0059973076,
#   0.011913753,
#   0.0019642867,
#   0.036657702,
#   -0.024407022,
#   0.016509444,
#   0.026805945,
#   0.005215636,
#   0.022668475,
#   -0.014501356,
#   -0.01787063,
#   -0.005842321,
#   0.0067587635,
#   -0.009946097,
#   0.0038578187,
#   0.027466321,
#   -0.014743943,
#   0.011132081,
#   0.018867934,
#   -0.020916453,
#   -0.024326159,
#   0.005609841,
#   0.011893537,
#   0.013760115,
#   -0.0050471723,
#   -0.011266853,
#   0.016657691,
#   0.018544484,
#   0.007944748,
#   -0.037008107,
#   -0.015539092,
#   0.018787071,
#   -0.0038679265,
#   -0.04196768,
#   -0.0064959605,
#   0.0021041117,
#   0.00909704,
#   0.009959574,
#   0.021522922,
#   -0.006563346,
#   0.0069339657,
#   0.0050202184,
#   0.011475747,
#   -0.0029733842,
#   0.006526284,
#   0.009245288,
#   -0.0056401645,
#   0.00227426,
#   0.024353113,
#   -0.014150951,
#   0.006994613,
#   0.030566053,
#   0.0018547854,
#   -0.0020518878,
#   0.011226421,
#   0.016967664,
#   -0.01401618,
#   0.0027459583,
#   -0.00023711266,
#   -0.008605125,
#   -0.024110524,
#   -0.016954187,
#   -0.031455543,
#   0.011792459,
#   0.0004043129,
#   0.015309981,
#   0.009656339,
#   0.019757424,
#   0.010181946,
#   -0.0026920498,
#   0.0007361864,
#   0.015539092,
#   0.006677901,
#   -0.01072103,
#   -0.03239894,
#   -0.002867252,
#   -0.0119744,
#   -0.011933968,
#   0.0027745971,
#   0.045283042,
#   -0.016307287,
#   0.013497312,
#   0.0042857165,
#   0.019137476,
#   -0.0063207583,
#   -0.0053840997,
#   -0.01411052,
#   -0.023504056,
#   0.014946099,
#   -0.0068935347,
#   -0.011098389,
#   0.009770894,
#   -0.020296507,
#   -0.024663085,
#   -0.0022136131,
#   0.003948789,
#   -0.004474396,
#   -0.011226421,
#   -0.010518873,
#   -0.023477102,
#   0.0064858524,
#   0.0041408376,
#   -0.004979787,
#   0.0060714316,
#   -0.028140176,
#   -0.010343671,
#   -0.013018874,
#   0.0040835603,
#   0.018544484,
#   -0.022722384,
#   -0.00065406034,
#   -0.009225072,
#   -0.020714296,
#   -0.02626686,
#   0.020498663,
#   -0.0117115965,
#   -0.030566053,
#   -0.005087604,
#   -0.012567392,
#   -0.001134603,
#   -0.0010453173,
#   0.014690035,
#   -0.01517521,
#   -0.020431278,
#   0.0011447108,
#   0.027398936,
#   -0.025876025,
#   0.011502702,
#   0.01452831,
#   0.01694071,
#   0.015902974,
#   0.021320766,
#   0.012985182,
#   0.0015776625,
#   0.015970359,
#   -0.015552569,
#   -0.0023669149,
#   0.020862544,
#   -0.006020893,
#   -0.010390841,
#   0.01308626,
#   -0.0056165797,
#   0.0042991936,
#   -0.022708908,
#   0.017398931,
#   0.018867934,
#   0.00024869453,
#   0.021495968,
#   0.008247983,
#   0.01411052,
#   -0.01002696,
#   0.0031586944,
#   -0.033989236,
#   -0.003541107,
#   -0.025929933,
#   0.009433967,
#   0.012041786,
#   0.003337266,
#   -0.020336937,
#   -0.026981147,
#   0.004006067,
#   0.010188685,
#   0.02005392,
#   -0.0038746651,
#   -0.0036960936,
#   -0.0013148591,
#   0.0011590302,
#   0.008611864,
#   -0.006297173,
#   0.017924538,
#   -0.006981136,
#   -0.0077493303,
#   0.019460926,
#   0.016159039,
#   0.03749328,
#   0.011051219,
#   -0.014609172,
#   -0.0009273927,
#   0.0055289785,
#   -0.0012744279,
#   -0.00035609014,
#   0.027062008,
#   0.013261463,
#   0.019258771,
#   -0.016792461,
#   0.038948808,
#   -0.0059467684,
#   -0.016307287,
#   0.021320766,
#   0.021361196,
#   -0.01327494,
#   0.01443397,
#   -0.02199462,
#   0.01517521,
#   0.019973056,
#   -0.00811995,
#   0.0004270555,
#   0.0014075142,
#   0.013504051,
#   -0.008025611,
#   0.013557958,
#   0.026698127,
#   -0.0068598418,
#   -0.0015936666,
#   0.010080867,
#   0.004905663,
#   0.016266854,
#   0.018584916,
#   -0.013092998,
#   -0.0033204195,
#   0.0049494635,
#   0.020862544,
#   -0.006832888,
#   -0.002353438,
#   -0.0049629407,
#   -0.017857153,
#   0.00059257104,
#   0.0050336956,
#   -0.012850411,
#   0.012917796,
#   -0.017291114,
#   0.021832896,
#   0.008450139,
#   0.016253378,
#   0.008915099,
#   0.0015540776,
#   -0.005117927,
#   -0.017115911,
#   -0.037924547,
#   0.0013527635,
#   0.011064696,
#   0.0059804614,
#   -0.0015481814,
#   -0.0077156373,
#   0.016684646,
#   -0.01452831,
#   -0.0005445589,
#   0.006148925,
#   0.005518871,
#   0.007836931,
#   -0.011266853,
#   0.004107145,
#   0.012836934,
#   0.003931943,
#   0.0036320775,
#   -0.01870621,
#   0.010417795,
#   0.011266853,
#   -0.0021007424,
#   -0.02398923,
#   -0.024245296,
#   0.043638837,
#   -0.013712945,
#   -0.0071159066,
#   0.0019407019,
#   -0.009292458,
#   -0.021239903,
#   0.012035047,
#   0.0024107154,
#   -0.021967666,
#   -0.00087601127,
#   0.019339632,
#   0.0009400275,
#   -0.011239898,
#   0.015013485,
#   0.025754731,
#   0.007978441,
#   0.0017975076,
#   -0.028571444,
#   -0.013854454,
#   0.0122506805,
#   0.06016176,
#   0.051293828,
#   0.005751351,
#   0.0039218348,
#   0.008322107,
#   -0.005373992,
#   -0.013463619,
#   -0.013463619,
#   0.017398931,
#   -0.021199472,
#   -0.0061388174,
#   -0.00468666,
#   0.019474404,
#   0.0026398262,
#   0.022210253,
#   -0.0067351786,
#   0.010390841,
#   0.0138005465,
#   -0.011529656,
#   -0.018261464,
#   0.0079245325,
#   0.010458226,
#   0.00093497353,
#   0.008611864,
#   0.020754728,
#   -0.022560658,
#   0.010067391,
#   0.014380061,
#   -0.0066341003,
#   -0.024514837,
#   -0.016442057,
#   0.016455535,
#   0.016859848,
#   0.023652304,
#   -0.0037938026,
#   0.030943412,
#   -0.010950141,
#   -0.013827501,
#   0.0051954207,
#   0.0036994629,
#   0.008429924,
#   0.006020893,
#   0.010970356,
#   0.0032985192,
#   -0.0021681278,
#   0.003141848,
#   -0.021981144,
#   0.0032075488,
#   -0.013376018,
#   -0.0033305273,
#   0.0017284376,
#   -0.007452834,
#   0.018167125,
#   -0.0130256135,
#   0.01768195,
#   0.018557962,
#   0.009460921,
#   0.010525612,
#   -0.006526284,
#   -0.025835592,
#   -0.0055491943,
#   -0.0016484173,
#   -0.009568738,
#   -0.009285719,
#   -0.00436321,
#   -0.02469004,
#   -0.010667122,
#   -0.0013544481,
#   -0.02580864,
#   0.010330194,
#   0.0074056643,
#   0.0021832895,
#   -0.014541787,
#   0.003369274,
#   0.011192728,
#   0.0014353107,
#   -0.0035849076,
#   -0.0047506765,
#   -0.010687337,
#   -0.00024637816,
#   -0.006927227,
#   -0.014272245,
#   0.011475747,
#   -0.02273586,
#   -0.0008566379,
#   0.015943404,
#   0.00059383456,
#   0.0011430262,
#   0.00034071784,
#   0.026981147,
#   -0.0049831565,
#   0.00858491,
#   -0.009831541,
#   -0.03161727,
#   -0.0022405672,
#   -0.018167125,
#   0.0060444777,
#   -0.01266847,
#   -0.0045047193,
#   -0.020808637,
#   -0.010876017,
#   -0.00026090816,
#   -0.00040473405,
#   -0.0061556636,
#   0.0035107834,
#   0.0009947781,
#   -0.0014748997,
#   0.012863888,
#   -0.008059303,
#   -0.0019053244,
#   0.004723722,
#   -0.011199467,
#   -0.001174192,
#   -0.013349064,
#   0.011381407,
#   0.013032352,
#   -0.006169141,
#   0.024986535,
#   0.0022911064,
#   -0.015431275,
#   0.012850411,
#   -0.01973047,
#   0.013402972,
#   0.024905674,
#   0.009319412,
#   0.023180606,
#   -0.02260109,
#   -0.004885447,
#   0.0036219696,
#   -0.012991921,
#   -0.00793801,
#   0.008416447,
#   -0.0021866588,
#   -0.018625347,
#   -0.026401632,
#   -0.0019524943,
#   0.0013140169,
#   0.009272242,
#   -0.023086265,
#   -0.01188006,
#   -0.01880055,
#   0.0050067413,
#   0.0095485225,
#   -0.0037230477,
#   -0.0112466365,
#   -0.025876025,
#   -0.003202495,
#   -0.002478101,
#   -0.012291112,
#   0.016576828,
#   0.00524596,
#   -0.0046024285,
#   -0.008288414,
#   -0.0028436673,
#   0.0046933987,
#   -0.025539096,
#   0.009575477,
#   0.010586259,
#   0.018544484,
#   0.017978447,
#   0.026051227,
#   -0.0004898082,
#   0.015566046,
#   0.011967661,
#   -0.008935315,
#   -0.0026330876,
#   0.0049359864,
#   -0.010700814,
#   -0.016698122,
#   -0.0027257428,
#   0.010545827,
#   0.011563349,
#   0.010747984,
#   -0.018881412,
#   0.0131806,
#   0.0051078196,
#   -0.0044811345,
#   0.0031384788,
#   0.004781,
#   -0.023005404,
#   -0.008342323,
#   0.011435316,
#   -0.013214293,
#   0.0146496035,
#   -0.029083574,
#   0.0027004732,
#   0.051940728,
#   -0.005751351,
#   0.0065566073,
#   0.0046057976,
#   0.008672511,
#   -0.015714293,
#   -0.0017132758,
#   -0.02018869,
#   -0.000444323,
#   -0.013126692,
#   0.016913755,
#   -0.02125338,
#   0.0034737214,
#   0.04617253,
#   0.016657691,
#   0.003318735,
#   0.003387805,
#   0.019703515,
#   0.0073315403,
#   -0.019043136,
#   0.010134776,
#   0.0024022923,
#   -0.003401282,
#   0.00057446124,
#   -0.032156352,
#   0.0028689369,
#   -0.003049193,
#   -0.011239898,
#   -0.002371969,
#   0.019097045,
#   0.006421836,
#   0.0059703537,
#   -0.036576837,
#   -0.013975749,
#   -0.0028167132,
#   -0.0135646975,
#   0.051967684,
#   0.017628042,
#   -0.0020872653,
#   0.013881409,
#   -0.008281675,
#   -0.015471706,
#   0.016495965,
#   -0.00793801,
#   -0.011145558,
#   0.04320757,
#   0.0318329,
#   -0.0071698152,
#   0.0027779664,
#   0.010464965,
#   0.024474407,
#   0.012129387,
#   -0.013194077,
#   0.010020221,
#   0.017654996,
#   -0.0013662406,
#   -0.021698125,
#   -0.009009439,
#   -0.0527224,
#   0.026940715,
#   0.0059467684,
#   0.0018312004,
#   -0.011718335,
#   -0.009076824,
#   -0.019986533,
#   0.005842321,
#   -0.01726416,
#   0.019528313,
#   0.008645557,
#   -0.012028309,
#   -0.011563349,
#   0.013840978,
#   -0.024393544,
#   -0.004329517,
#   -0.0051314044,
#   0.018072786,
#   -0.024056617,
#   0.004622644,
#   0.008625342,
#   0.019474404,
#   -0.012661732,
#   0.000411262,
#   0.00053192413,
#   0.028840985,
#   -0.016266854,
#   -0.007035044,
#   -0.0026752036,
#   -0.0008878037,
#   0.0100067435,
#   -0.0047169835,
#   -0.0040768217,
#   -0.005495286,
#   -0.011482486,
#   -0.01443397,
#   0.0056233183,
#   0.008470355,
#   -0.012742594,
#   -0.017951492,
#   -0.0054009464,
#   -0.021132087,
#   -0.012055262,
#   -0.013153646,
#   0.00026806787,
#   -0.030134786,
#   -0.036630746,
#   0.016388148,
#   0.010431272,
#   0.013369279,
#   0.0059973076,
#   -0.019865239,
#   0.020390846,
#   0.039973065,
#   -0.004929248,
#   0.0050572804,
#   0.0034501366,
#   0.0043834257,
#   -0.022574136,
#   -0.0016037744,
#   -0.008187336,
#   0.0016442058,
#   0.02130729,
#   -0.01814017,
#   -0.027681956,
#   -0.011839629,
#   -0.00050370645,
#   0.013638821,
#   0.0038376031,
#   -0.015512138,
#   0.004710245,
#   0.005424531,
#   0.0037735868,
#   0.018369282,
#   -0.025741253,
#   0.02269543,
#   -0.00097372016,
#   -0.006431944,
#   -0.0011960922,
#   -0.023706213,
#   -0.00035693246,
#   0.0048281695,
#   0.00752022,
#   0.011435316,
#   -0.040296517,
#   -0.018126694,
#   -0.002361861,
#   0.015336935,
#   -0.003369274,
#   -0.010336933,
#   -0.021846373,
#   -0.0010941718,
#   -0.009380058,
#   -0.003397913,
#   0.018167125,
#   -0.014555263,
#   -0.007951487,
#   0.00988545,
#   -0.0044305953,
#   0.008557956,
#   -0.0075808666,
#   0.01099731,
#   -0.035256084,
#   -0.016832894,
#   -0.016536396,
#   -0.01851753,
#   -0.006401621,
#   0.025714299,
#   0.008659034,
#   -0.007351756,
#   -0.016172515,
#   -0.012681947,
#   -0.039191395,
#   -0.022964971,
#   -0.006182618,
#   -0.0023669149,
#   0.021320766,
#   0.030593008,
#   -0.001568397,
#   0.0305391,
#   -0.0010065706,
#   0.033234518,
#   -0.0353639,
#   -0.011172513,
#   0.017250683,
#   -0.019285724,
#   -0.0075673894,
#   0.0068295184,
#   -0.019501358,
#   -0.0068261493,
#   0.038948808,
#   0.0045552584,
#   -0.0036725088,
#   0.03336929,
#   -0.0019440711,
#   -0.027628047,
#   -0.008086258,
#   0.0069541815,
#   0.0010705868,
#   -0.00770216,
#   0.0011261798,
#   -0.0071900305,
#   -0.010801893,
#   -0.0023231145,
#   -0.013221031,
#   -0.0072574164,
#   0.004093668,
#   0.0104717035,
#   0.00192554,
#   0.00580189,
#   -0.027075486,
#   -0.012985182,
#   -0.018490575,
#   -0.01475742,
#   0.027412413,
#   0.0046260133,
#   -0.014973054,
#   0.03690029,
#   -0.009063347,
#   -0.0030053924,
#   -0.016226424,
#   0.023328854,
#   -0.016603783,
#   -0.0124797905,
#   0.0026330876,
#   -0.023315376,
#   -0.023450147,
#   -0.0031772254,
#   -0.005124666,
#   -0.021684647,
#   0.0072776317,
#   -0.0050438032,
#   -0.010134776,
#   -0.015768202,
#   -0.008793805,
#   0.00654313,
#   -0.024770902,
#   -0.045687355,
#   -0.023045834,
#   0.018409714,
#   -0.0006502699,
#   -0.00937332,
#   -0.011792459,
#   -0.014878714,
#   0.021401629,
#   0.010835585,
#   -0.011900276,
#   -0.0075539122,
#   0.019932626,
#   0.011886799,
#   -0.019043136,
#   0.021051224,
#   0.22964972,
#   -0.00021447535,
#   0.012991921,
#   0.04075474,
#   0.013288417,
#   0.012398928,
#   0.014946099,
#   0.0015111194,
#   -0.010687337,
#   0.007574128,
#   0.0070956913,
#   0.0039656353,
#   -0.0014117258,
#   -0.00031439538,
#   0.027358506,
#   0.0128706265,
#   -0.02083559,
#   -0.040215656,
#   -0.01160378,
#   -0.02938007,
#   -0.0007142861,
#   -0.0044474415,
#   -0.00025290612,
#   -0.010619951,
#   0.0058692754,
#   -0.008982484,
#   -0.011118604,
#   -0.003824126,
#   0.018989228,
#   0.015242595,
#   -0.010384102,
#   -0.013376018,
#   0.010370625,
#   0.0076415134,
#   -0.04223722,
#   0.020956885,
#   0.014946099,
#   0.011482486,
#   0.022398934,
#   0.014366585,
#   0.0014951153,
#   -0.017318068,
#   -0.023140173,
#   -0.018921843,
#   -0.0016644214,
#   0.014150951,
#   0.007991918,
#   -0.019784378,
#   0.008483832,
#   0.0022995295,
#   -0.009845018,
#   0.014191383,
#   0.020390846,
#   0.012351759,
#   0.00895553,
#   -0.0072237235,
#   0.016630737,
#   0.013672514,
#   -0.024070093,
#   0.010485181,
#   -0.008099735,
#   0.015795156,
#   -0.005117927,
#   0.01749327,
#   -0.011253376,
#   -0.005161728,
#   -0.015377367,
#   -0.020956885,
#   -0.014460924,
#   -0.0020872653,
#   0.002885783,
#   0.0054312698,
#   -0.0017941385,
#   0.0013333902,
#   -0.006347712,
#   -0.01452831,
#   0.0067183324,
#   0.02873317,
#   0.017695427,
#   0.02756066,
#   -0.020134782,
#   0.00096782396,
#   0.01870621,
#   -0.023355808,
#   -0.025714299,
#   -0.022843678,
#   -0.0026516186,
#   0.00095434685,
#   -0.009804588,
#   -0.017088957,
#   -0.017843675,
#   -0.012500007,
#   -0.0125606535,
#   -0.015970359,
#   0.017708905,
#   0.0018278311,
#   -0.015983837,
#   0.016078176,
#   -0.0066273618,
#   -0.0009989898,
#   -0.032506756,
#   0.039649617,
#   0.004019544,
#   0.01475742,
#   0.0038746651,
#   0.00012940117,
#   -0.0045316736,
#   0.006886796,
#   -0.009433967,
#   -0.011799198,
#   0.019514835,
#   0.0063982513,
#   0.015673863,
#   -0.008254722,
#   -0.012365236,
#   0.021145564,
#   0.002660042,
#   -0.017048527,
#   0.0021142194,
#   0.0039656353,
#   -0.019905671,
#   -0.005303237,
#   -0.01680594,
#   0.004312671,
#   -0.016536396,
#   -0.013052568,
#   -0.0055289785,
#   -0.004821431,
#   0.01248653,
#   -0.014905668,
#   0.003578169,
#   0.007486527,
#   0.006613885,
#   0.00341139,
#   -0.0071630767,
#   3.271881e-05,
#   0.0005382415,
#   0.011388146,
#   -0.01973047,
#   0.015471706,
#   0.010053914,
#   -0.00807278,
#   0.0019878717,
#   -0.013389495,
#   0.0016172515,
#   -0.005026957,
#   0.009649601,
#   -0.019231817,
#   -0.0019154323,
#   -0.017008096,
#   -0.027223734,
#   -0.013288417,
#   -0.008247983,
#   0.008045826,
#   0.02881403,
#   -0.016711598,
#   -0.018962273,
#   -0.027250689,
#   0.016361194,
#   -0.0146496035,
#   -0.034043144,
#   -0.00054245314,
#   0.026805945,
#   -0.018827504,
#   0.0033355812,
#   -0.0028369287,
#   -0.1761726,
#   0.0017419147,
#   0.017601088,
#   -0.022722384,
#   0.008800544,
#   -0.0124056665,
#   0.026051227,
#   0.006974397,
#   -0.00062289456,
#   0.003253034,
#   -0.0074730497,
#   -0.015283027,
#   -0.0353639,
#   -0.0062533724,
#   -0.013699468,
#   0.006223049,
#   -0.034797862,
#   0.010849062,
#   0.018975751,
#   0.029164435,
#   0.0037432634,
#   -0.010707553,
#   0.019110521,
#   -0.031105138,
#   0.008524263,
#   -0.005704181,
#   -0.006927227,
#   0.026994623,
#   -0.0044070105,
#   -0.007823454,
#   0.0035950153,
#   -0.004690029,
#   -0.0022388825,
#   0.0052223746,
#   0.011994615,
#   -0.0024292467,
#   0.010694075,
#   -0.0029245298,
#   -0.009487876,
#   0.020822113,
#   0.014353108,
#   0.04121296,
#   0.0032614572,
#   -0.024218341,
#   0.0018194079,
#   0.007304586,
#   0.019905671,
#   -0.0046765525,
#   0.0017739228,
#   -0.013342325,
#   0.022304595,
#   -0.034366596,
#   -0.0061219707,
#   -0.0025825484,
#   0.0001508803,
#   -0.00069322815,
#   0.0032917806,
#   -0.013322109,
#   -0.0061388174,
#   0.008355799,
#   0.015835587,
#   -0.035283037,
#   0.010761461,
#   0.025997318,
#   -0.010619951,
#   -0.011967661,
#   -0.026859852,
#   0.013072783,
#   -0.008167121,
#   0.009669816,
#   -0.01846362,
#   -0.02167117,
#   -0.008281675,
#   -0.005902968,
#   0.0028790447,
#   -0.009973051,
#   -0.026145566,
#   0.022398934,
#   -0.01067386,
#   -0.009022916,
#   -0.026118612,
#   0.02463613,
#   -0.007412403,
#   0.019339632,
#   0.004366579,
#   0.01508087,
#   -0.020539094,
#   -0.008126689,
#   0.0054784394,
#   0.013382756,
#   0.044717006,
#   -0.008712943,
#   -0.015808634,
#   -0.0040532365,
#   0.0036826164,
#   0.01880055,
#   -0.0017890845,
#   0.01948788,
#   0.0039555277,
#   0.0023096374,
#   -0.0016939025,
#   -0.020673865,
#   -0.009582215,
#   0.010249332,
#   0.029245298,
#   0.01475742,
#   0.013814024,
#   -0.0036118617,
#   0.02195419,
#   -0.00034766697,
#   -0.04576822,
#   0.0043362556,
#   0.015242595,
#   0.012291112,
#   -0.005966984,
#   0.037762824,
#   -0.022843678,
#   -0.033477105,
#   0.0059973076,
#   -0.0023130067,
#   0.040943418,
#   0.007412403,
#   -0.0021698126,
#   0.0115566095,
#   0.010229116,
#   -0.008497309,
#   -0.083611906,
#   -0.012654993,
#   0.018719686,
#   0.034609184,
#   -0.018207557,
#   0.015202165,
#   -0.01165095,
#   0.020714296,
#   0.004959571,
#   0.0019221709,
#   0.003054247,
#   -0.018773595,
#   -0.008274937,
#   -0.022870632,
#   0.024353113,
#   0.012358497,
#   -0.00065995654,
#   -0.0057985205,
#   -0.001610513,
#   0.021846373,
#   -0.009784372,
#   -0.0026566726,
#   0.013369279,
#   -0.013295155,
#   0.002451147,
#   -0.005990569,
#   -0.027547184,
#   0.02324799,
#   0.007412403,
#   -0.011677904,
#   -0.0035747997,
#   -0.009845018,
#   0.020956885,
#   -0.013039091,
#   -0.004797846,
#   0.017708905,
#   -0.042803258,
#   -0.009326151,
#   0.007082214,
#   -0.007681945,
#   0.002464624,
#   0.026603788,
#   0.01401618,
#   -0.04013479,
#   0.00072776317,
#   -0.011987877,
#   -0.007884101,
#   0.037574142,
#   0.0052560675,
#   -0.027277643,
#   -0.03555258,
#   0.016334241,
#   -0.030269558,
#   -0.009299196,
#   0.03008088,
#   0.016442057,
#   0.022345025,
#   -0.0016543135,
#   -0.0051853126,
#   -0.0076886835,
#   -0.0067688716,
#   -0.009103779,
#   -0.0026735188,
#   0.030000016,
#   -0.004797846,
#   0.0054009464,
#   -0.01642858,
#   0.00092233875,
#   -0.0012390505,
#   -0.0138005465,
#   0.004097037,
#   0.0022944757,
#   -0.011219682,
#   0.02092993,
#   -0.007904317,
#   -0.0044204877,
#   -0.030107833,
#   -0.024433976,
#   0.012971705,
#   -0.0052796523,
#   -0.017318068,
#   -0.016280333,
#   -0.010498658,
#   0.0040869294,
#   0.02125338,
#   0.023382762,
#   0.0041037756,
#   0.0047338298,
#   0.014555263,
#   -0.035336945,
#   0.018625347,
#   0.041617274,
#   -0.008969007,
#   -0.021792464,
#   -0.0045518894,
#   0.006664424,
#   -0.00083010487,
#   0.005053911,
#   0.0072372006,
#   -0.0040667136,
#   -0.0395418,
#   -0.02622643,
#   -0.065175235,
#   0.011765505,
#   0.01062669,
#   -0.024609178,
#   -0.0036219696,
#   0.018301897,
#   -0.004868601,
#   -0.004134099,
#   -0.017345022,
#   0.006708225,
#   -0.026024273,
#   0.005876014,
#   0.008787067,
#   -0.0011354453,
#   -0.02626686,
#   -0.0036017539,
#   0.020579526,
#   0.0018648931,
#   0.025377372,
#   0.025876025,
#   0.0008869614,
#   -0.021428583,
#   -0.0029784383,
#   0.010929924,
#   -0.014326153,
#   0.005582887,
#   -0.029784381,
#   0.02691376,
#   -0.010283024,
#   -0.021159042,
#   -0.0020822114,
#   -0.039083578,
#   0.003541107,
#   0.011024265,
#   -0.00097119325,
#   -0.0025657022,
#   -0.004417118,
#   0.032938022,
#   0.005370623,
#   0.015202165,
#   -0.008335584,
#   -0.022493273,
#   0.0068800575,
#   -0.02520217,
#   0.0024006078,
#   0.028382765,
#   -0.025862547,
#   -0.01995958,
#   0.035579532,
#   0.009346366,
#   0.011967661,
#   -0.0038443417,
#   -0.028328856,
#   -0.024218341,
#   -0.008652296,
#   -0.008739897,
#   0.014420493,
#   0.0015035386,
#   0.017668473,
#   -0.011031003,
#   0.035768215,
#   -0.0058861217,
#   -0.0023652303,
#   0.008638819,
#   -0.008706204,
#   0.009413752,
#   -0.028571444,
#   0.0055795177,
#   -0.008510786,
#   -0.021617262,
#   -0.03517522,
#   -0.023288421,
#   -0.010485181,
#   0.038167138,
#   0.026994623,
#   0.016927233,
#   -0.008160382,
#   0.022304595,
#   0.0071024294,
#   0.027870635,
#   0.019663082,
#   0.021334244,
#   -0.008052565,
#   0.009299196,
#   0.04218331,
#   0.016644213,
#   -0.022587612,
#   0.004349733,
#   -0.013450142,
#   0.009690032,
#   -0.010896232,
#   0.010714292,
#   0.013840978,
#   0.0012289427,
#   -0.008524263,
#   -0.013908363,
#   4.984815e-07,
#   0.00436321,
#   0.021940712,
#   0.0180054,
#   0.0051347734,
#   0.009535045,
#   -0.0028453518,
#   -0.023544487,
#   -0.008969007,
#   -0.003072778,
#   -0.036684655,
#   -0.047088973,
#   -0.0006873319,
#   0.020849068,
#   -0.007863886,
#   -0.013362541,
#   0.015983837,
#   0.014487878,
#   -0.034582227,
#   0.016698122,
#   -0.013402972,
#   -0.010485181,
#   -0.036307298,
#   0.031293817,
#   -0.0146496035,
#   -0.001721699,
#   0.039433982,
#   -0.008969007,
#   0.023490578,
#   0.008780328,
#   0.024663085,
#   -0.016549874,
#   -0.00017941384,
#   0.008180597,
#   -0.007035044,
#   0.018045831,
#   -0.012803242,
#   -0.026563356,
#   0.0026145566,
#   -0.011017526,
#   -0.0142587675,
#   0.04463614,
#   -0.0037230477,
#   0.07493266,
#   -0.0028975757,
#   -0.00904987,
#   0.01104448,
#   -0.015593,
#   0.027655002,
#   0.02138815,
#   0.014407015,
#   -0.012304589,
#   0.0070956913,
#   0.022587612,
#   0.0071293837,
#   -0.0010284709,
#   -0.016725076,
#   -0.020849068,
#   -0.012493268,
#   -0.010020221,
#   0.011576826,
#   0.0031856485,
#   0.0020805267,
#   0.014272245,
#   -0.0050977115,
#   0.02111861,
#   0.016549874,
#   -0.01035041,
#   -0.0025000013,
#   0.02816713,
#   -0.02723721,
#   -0.010923186,
#   -0.016603783,
#   -0.0021091655,
#   -0.003982482,
#   -0.022264162,
#   -0.025188692,
#   0.00041610535,
#   0.0154177975,
#   -0.008234506,
#   -0.02723721,
#   -0.0056873346,
#   0.009016178,
#   0.0039588967,
#   0.028194085,
#   -0.013814024,
#   0.0024612546,
#   -0.034124006,
#   0.011145558,
#   -0.009353105,
#   -0.00062794844,
#   -0.013443403
# ]
