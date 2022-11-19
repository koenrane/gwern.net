/**********************************/
/*	Events fired by annotations.js:

	Annotations.didLoad
		Fired when the Annotations object has loaded.

	Annotations.annotationDidLoad {
			identifier:
				The identifier string for the annotation. (See the
				Extracts.targetIdentifier function in extracts.js for details.)
		}
		Fired after a new annotation has been loaded and cached.

	Annotations.annotationLoadDidFail {
			identifier:
				The identifier string for the annotation. (See the
				Extracts.targetIdentifier function in extracts.js for details.)
		}
		Fired when a new annotation has failed to load, and the load failure
		has been recorded in the annotations cache.
 */

Annotations = {
	annotatedLinkFullClass: "link-annotated",
	annotatedLinkPartialClass: "link-annotated-partial"
};

Annotations = { ...Annotations,
    /***********/
    /*  General.
        */

	isAnnotatedLink: (link) => {
		return link.classList.containsAnyOf([ Annotations.annotatedLinkFullClass,  Annotations.annotatedLinkPartialClass ]);
	},

	isAnnotatedLinkFull: (link) => {
		return link.classList.contains(Annotations.annotatedLinkFullClass);
	},

	isAnnotatedLinkPartial: (link) => {
		return link.classList.contains(Annotations.annotatedLinkPartialClass);
	},

    allAnnotatedLinksInContainer: (container) => {
        return Array.from(container.querySelectorAll("a[class*='link-annotated']")).filter(link => Annotations.isAnnotatedLink(link));
    },

    /*  Storage for retrieved and cached annotations.
        */
    cachedReferenceData: { },

    /*  Returns true iff a processed and cached annotation exists for the given
        identifier string.
        */
    //	Called by: Extracts.setUpAnnotationLoadEventWithin (extracts-annotations.js)
    cachedAnnotationExists: (identifier) => {
        let cachedAnnotation = Annotations.cachedReferenceData[identifier];
        return (cachedAnnotation && cachedAnnotation != "LOADING_FAILED");
    },

    /*  Returns cached annotation reference data for a given identifier string,
    	or else either “LOADING_FAILED” (if loading the annotation was attempted
    	but failed) or null (if the annotation has not been loaded).
        */
    //	Called by: Extracts.annotationForTarget (extracts-annotations.js)
    referenceDataForAnnotationIdentifier: (identifier) => {
        return Annotations.cachedReferenceData[identifier];
    },

	//	Called by: Annotations.sourceURLForIdentifier
	//	Called by: Annotations.processedAPIResponseForIdentifier
	//	Called by: Annotations.referenceDataFromParsedAPIResponse
	dataSourceForIdentifier: (identifier) => {
		for ([ sourceName, dataSource ] of Object.entries(Annotations.dataSources))
			if (   sourceName != "local"
				&& dataSource.matches(identifier))
				return dataSource;

		return Annotations.dataSources.local;
	},

	/*	Returns the URL of the annotation resource for the given identifier.
	 */
	//	Called by: Annotations.loadAnnotation
	//	Called by: Annotations.cachedAPIResponseForIdentifier
	//	Called by: Annotations.cacheAPIResponseForIdentifier
	sourceURLForIdentifier: (identifier) => {
		return Annotations.dataSourceForIdentifier(identifier).sourceURLForIdentifier(identifier);
	},

	//	Called by: Annotations.loadAnnotation
	processedAPIResponseForIdentifier: (response, identifier) => {
		return Annotations.dataSourceForIdentifier(identifier).processAPIResponse(response);
	},

	//	Used by: Annotations.cachedAPIResponseForIdentifier
	//	Used by: Annotations.cacheAPIResponseForIdentifier
	cachedAPIResponses: { },

	//	Called by: Annotations.loadAnnotation
	cachedAPIResponseForIdentifier: (identifier) => {
		return Annotations.cachedAPIResponses[Annotations.sourceURLForIdentifier(identifier)];
	},

	//	Called by: Annotations.loadAnnotation
	cacheAPIResponseForIdentifier: (response, identifier) => {
		Annotations.cachedAPIResponses[Annotations.sourceURLForIdentifier(identifier)] = response;
	},

    /*  Load and process the annotation for the given identifier string.
        */
    //	Called by: Extracts.setUpAnnotationLoadEventWithin (extracts-annotations.js)
    loadAnnotation: (identifier) => {
        GWLog("Annotations.loadAnnotation", "annotations.js", 2);

		/*	Get URL of the annotation resource.
		 */
        let sourceURL = Annotations.sourceURLForIdentifier(identifier);

		/*	Depending on the data source, `response` could be HTML,
			JSON, or other. We construct and cache a reference data object,
			then fire the appropriate event.
		 */
		let processResponse = (response) => {
			let referenceData = Annotations.referenceDataFromParsedAPIResponse(response, identifier);

			if (referenceData) {
				Annotations.cachedReferenceData[identifier] = referenceData;

				GW.notificationCenter.fireEvent("Annotations.annotationDidLoad", { identifier: identifier });
			} else {
				Annotations.cachedReferenceData[identifier] = "LOADING_FAILED";

				GW.notificationCenter.fireEvent("Annotations.annotationLoadDidFail", { identifier: identifier });

				//	Send request to record failure in server logs.
				GWServerLogError(sourceURL + `--could-not-process`, "problematic annotation");
			}
		};

		/*	Retrieve, parse, and cache the annotation resource; or use an
			already-cached API response.
		 */
		let response = Annotations.cachedAPIResponseForIdentifier(identifier);
		if (response) {
			processResponse(response);
		} else {
			doAjax({
				location: sourceURL.href,
				onSuccess: (event) => {
					let response = Annotations.processedAPIResponseForIdentifier(event.target.responseText, identifier);

					Annotations.cacheAPIResponseForIdentifier(response, identifier);

					processResponse(response);
				},
				onFailure: (event) => {
					Annotations.cachedReferenceData[identifier] = "LOADING_FAILED";

					GW.notificationCenter.fireEvent("Annotations.annotationLoadDidFail", { identifier: identifier });

					//	Send request to record failure in server logs.
					GWServerLogError(sourceURL, "missing annotation");
				}
			});
		}
    },

	//	Called by: Annotations.loadAnnotation
	referenceDataFromParsedAPIResponse: (response, identifier) => {
		return Annotations.dataSourceForIdentifier(identifier).referenceDataFromParsedAPIResponse(response, identifier);
	},

	/***************************/
	/* ANNOTATION DATA SOURCES */
	/***************************/
	/*	Note on annotation data sources:

		More data sources may be added. Any data source object must have these
		four properties, each a function with the given signature:

		matches: (string) => boolean
		sourceURLForIdentifier: (string) => string
		processAPIResponse: (string) => object
		referenceDataFromParsedAPIResponse: (string|object, string) => object

		(Most data source objects also have additional properties, functions,
		 etc., as necessary to implement the above functionality.)

		Examine implementation of these functions in .dataSources.local to
		understand their purpose.
	 */

	dataSources: {
		/********************************************************/
		/*	Annotations generated server-side and hosted locally.
		 */

		local: {
			/*	There could be a local annotation for any identifier. As this
				returns true for all identifiers, it is the fallback data source
				in the event that no other data sources match an identifier.
			 */
			matches: (identifier) => {
				return true;
			},

			//	Called by: Annotations.processedAPIResponseForIdentifier
			//	Called by: Annotations.sourceURLForIdentifier
			sourceURLForIdentifier: (identifier) => {
				return new URL("https://"
							   + location.hostname
							   + Annotations.dataSources.local.basePathname
							   + fixedEncodeURIComponent(fixedEncodeURIComponent(identifier))
							   + ".html");
			},

			//	Called by: Annotations.processedAPIResponseForIdentifier
			processAPIResponse: (response) => {
				let responseDoc = newDocument(response);

				//	Request the image, to cache it.
				let thumbnail = responseDoc.querySelector(".page-thumbnail");
				if (thumbnail)
					doAjax({ location: new URL(thumbnail.src) });

				return responseDoc;
			},

			//	Called by: Annotations.referenceDataFromParsedAPIResponse
			referenceDataFromParsedAPIResponse: (referenceEntry, identifier) => {
				let referenceElement = referenceEntry.querySelector(Annotations.dataSources.local.referenceElementSelector);

				let titleHTML = referenceElement.innerHTML;
				let titleText = referenceElement.textContent;
				let titleLinkHref = referenceElement.href;

				let titleLinkClass = "title-link";
				//  Import certain link classes.
				/*  Just ‘link-live’ for now, but the inclusion rule is: any class that
					is used to test whether a link is of a certain type - see e.g.
					Extracts.isForeignSiteLink() in extracts-content.js - for which link
					type there can be annotations (so not, e.g., ‘footnote-ref’, because
					there’s no such thing as an annotated footnote link). This way, the
					title-link of the popup will correctly test as the *un-annotated*
					link type of the original target.
					—SA 2022-06-13
				 */
				[ "link-live" ].forEach(targetClass => {
					if (referenceElement.classList.contains(targetClass))
						titleLinkClass += ` ${targetClass}`;
				});

				//	Original URL.
				let originalURL = referenceElement.dataset.urlOriginal ?? null;
				let originalURLText = originalURL
									  ? (originalURL.includes("ar5iv") 
									     ? `<span class="smallcaps">HTML</span>` 
									     : "live")
									  : null;

				//  Author list.
				let authorElement = referenceEntry.querySelector(".author");
				//	Generate comma-separated author list; truncate with “…” abbreviation for 'et al' @ > 3.
				let authorList;
				if (authorElement) {
					authorList = authorElement.textContent.split(", ").slice(0, 3).join(", ");
					if (authorList.length < authorElement.textContent.length)
						authorList += "…";
				}
				let author = authorElement 
							 ? `<span class="data-field author cite-author">${authorList}</span>` 
							 : null;

				//  Date.
				let dateElement = referenceEntry.querySelector(".date");
				let date = dateElement 
						   ? (  `<span class="data-field cite-date" title="${dateElement.textContent}">` 
						      + dateElement.textContent.replace(/-[0-9][0-9]-[0-9][0-9]$/, "") 
						      + `</span>`) 
						   : null;

				// Link Tags
				let tagsElement = referenceEntry.querySelector(".link-tags");
				let tags = tagsElement
						   ? `<span class="data-field link-tags">${tagsElement.innerHTML}</span>`
						   : null;

				//	The backlinks link (if exists).
				let backlinksElement = referenceEntry.querySelector(".backlinks");
				let backlinks = backlinksElement
								? `<span 
									class="data-field aux-links backlinks" 
									>${backlinksElement.innerHTML}</span>`
								: null;

				//	The similar-links link (if exists).
				let similarsElement = referenceEntry.querySelector(".similars");
				let similars = similarsElement
							   ? `<span 
							       class="data-field aux-links similars"
							       >${similarsElement.innerHTML}</span>`
							   : null;

                //	The link-linkbibliography link (if exists).
				let linkbibElement = referenceEntry.querySelector(".linkbibliography");
				let linkbib = linkbibElement
							  ? `<span 
							  	  class="data-field aux-links linkbibliography"
							  	  >${linkbibElement.innerHTML}</span>`
							  : null;

				//	All the aux-links (tags, backlinks, similars, link link-bib).
				let auxLinks = ([ tags, backlinks, similars, linkbib ].filter(x => x).join("; ") || null);
				if (auxLinks)
					auxLinks = ` (${auxLinks})`;

				//  Combined author, date, & aux-links.
				let authorDateAux = ([ author, date, auxLinks ].filter(x => x).join("") || null);

				//	Abstract (if exists).
				let abstractElement = referenceEntry.querySelector("blockquote");
				//	Unwrap extraneous <div>s, if present.
				if (abstractElement) {
					if (   abstractElement.firstElementChild == abstractElement.lastElementChild
						&& abstractElement.firstElementChild.tagName == "DIV")
						unwrap(abstractElement.firstElementChild);

					let pageDescriptionClass = "page-description-annotation";
					let pageDescription = abstractElement.querySelector(`div.${pageDescriptionClass}`);
					if (pageDescription)
						unwrap(pageDescription, [ pageDescriptionClass ]);
				}
				let abstractHTML = abstractElement
								   ? abstractElement.innerHTML
								   : null;

				//	Pop-frame title text. Mark sections with ‘§’ symbol.
				/*  Annotations for local archive links with an org notation
					for link icons (eg. 'https://arxiv.org/abs/2006.07159#google')
					should not get a section mark.
				 */
				let noSectionMark = [
					"adobe", "alibaba", "allen", "amazon", "anthropic", "apple", 
					"baai", "baidu", "bair", "bytedance", "cerebras", "cohere", 
					"deepmind", "eleutherai", "elementai", "facebook", "flickr",
					"github", "google", "googledeepmind", "google-graphcore", 
					"graphcore", "huawei", "huggingface", "ibm", "intel", "jd", 
					"kako", "laion", "lighton", "microsoft", "microsoftnvidia", 
					"miri", "naver", "nvidia", "openai", "pinterest", "pdf", 
					"salesforce", "samsung", "sberbank", "schmidhuber", 
					"sensetime", "snapchat", "sony", "spotify", "tencent", 
					"tensorfork", "twitter", "uber", "yandex"
				].includes(referenceElement.hash.slice(1));
				let popFrameTitleText = ((   referenceElement.hash > "" 
										  && noSectionMark == false)
										 ? `&#x00a7; ${titleText.trimQuotes()}`
										 : titleText.trimQuotes());

				return {
					originalURL:        originalURL,
					originalURLText:    originalURLText,
					titleHTML:          titleHTML,
					fullTitleHTML:      titleHTML,
					titleText:          titleText,
					titleLinkHref:      titleLinkHref,
					titleLinkClass:     titleLinkClass,
                    authorDateAux:      authorDateAux,
					abstract:           abstractHTML,
					popFrameTitleText:  popFrameTitleText,
					template:           "annotation-blockquote-inside"
				};
			},

			basePathname: "/metadata/annotations/",
			referenceElementSelector: [ Annotations.annotatedLinkFullClass,  Annotations.annotatedLinkPartialClass ].map(className => `a.${className}`).join(", ")
		}
	}
};

/**************************************************/
/*  Wikipedia entries (page summaries or sections).
	*/
Annotations.dataSources.wikipedia = {
	/*	The Wikipedia API only gives usable responses for most, not all,
		Wikipedia URLs.
	 */
	matches: (identifier) => {
		//	The URL() constructor demands a fully qualified URL string.
		if (/^[\/]/.test(identifier))
			return false;

		let url = new URL(identifier);

		return (   url
				&& /(.+?)\.wikipedia\.org/.test(url.hostname)
				&& url.pathname.startsWith("/wiki/")
				&& !(url.pathname.startsWithAnyOf(_π("/wiki/", [ "File:", "Category:", "Special:" ]))));
	},

	//	Called by: Annotations.processedAPIResponseForIdentifier
	//	Called by: Annotations.sourceURLForIdentifier
	sourceURLForIdentifier: (identifier) => {
		annotationURL = new URL(identifier);

		let wikiPageName = fixedEncodeURIComponent(/\/wiki\/(.+?)$/.exec(decodeURIComponent(annotationURL.pathname))[1]);
		annotationURL.pathname = `/api/rest_v1/page/mobile-sections/${wikiPageName}`;
		annotationURL.hash = "";

		return annotationURL;
	},

	//	Called by: Annotations.processedAPIResponseForIdentifier
	processAPIResponse: (response) => {
		return JSON.parse(response);
	},

	//	Called by: Annotations.referenceDataFromParsedAPIResponse
	referenceDataFromParsedAPIResponse: (response, identifier) => {
		let articleURL = new URL(identifier);
		let titleLinkHref = articleURL.href;

		let responseHTML, titleHTML, fullTitleHTML;
		if (articleURL.hash > "") {
			let targetSection = response["remaining"]["sections"].find(section =>
				//	This MUST be decodeURIComponent, and NOT selectorFromHash!!!
				section["anchor"] == decodeURIComponent(articleURL.hash).slice(1)
			);

			/*	Check whether we have tried to load a page section which does
				not exist on the requested wiki page.
			 */
			if (!targetSection)
				return null;

			responseHTML = targetSection["text"];
			titleHTML = targetSection["line"];
			fullTitleHTML = `${targetSection["line"]} (${response["lead"]["displaytitle"]})`;
		} else {
			responseHTML = response["lead"]["sections"][0]["text"];
			titleHTML = response["lead"]["displaytitle"];
			fullTitleHTML = titleHTML;

			//	Build TOC.
			let sections = response["remaining"]["sections"];
			if (   sections 
				&& sections.length > 0) {
				responseHTML += `<div class="TOC columns"><ul>`;
				let headingLevel = 2;
				for (let i = 0; i < sections.length; i++) {
					let section = sections[i];
					let newHeadingLevel = 1 + parseInt(section["toclevel"]);
					if (newHeadingLevel > headingLevel)
						responseHTML += `<ul>`;

					if (   i > 0 
						&& newHeadingLevel <= headingLevel)
						responseHTML += `</li>`;

					if (newHeadingLevel < headingLevel)
						responseHTML += `</ul>`;

					//	We must encode, because the anchor might contain quotes.
					let urlEncodedAnchor = fixedEncodeURIComponent(section["anchor"]);
					responseHTML += `<li><a href='${articleURL}#${urlEncodedAnchor}'>${section["line"]}</a>`;

					headingLevel = newHeadingLevel;
				}
				responseHTML += `</li></ul></div>`;
			}
		}

		let referenceEntry = newDocument(responseHTML);
		Annotations.dataSources.wikipedia.postProcessReferenceEntry(referenceEntry, identifier);
		let abstractHTML = referenceEntry.innerHTML;

		let titleText = newElement("SPAN", null, { innerHTML: titleHTML }).textContent;

		//	Pop-frame title text. Mark sections with ‘§’ symbol.
		let popFrameTitleHTML = (articleURL.hash > ""
								 ? `${response["lead"]["displaytitle"]} &#x00a7; ${titleHTML}`
								 : titleHTML);
		let popFrameTitleText = newElement("SPAN", null, { innerHTML: popFrameTitleHTML }).textContent;

		return {
			titleHTML:              titleHTML,
			fullTitleHTML:          fullTitleHTML,
			titleText:              titleText,
			titleLinkHref:          titleLinkHref,
			titleLinkClass:         `title-link link-live`,
			titleLinkIconMetadata:  `data-link-icon-type="svg" data-link-icon="wikipedia"`,
			abstract: 		        abstractHTML,
			popFrameTitleText:      popFrameTitleText,
			dataSource:		        "wikipedia",
			dataSourceClass:        "wikipedia-entry",
			template:               "annotation-blockquote-inside"
		};
	},

	/*  Elements to excise from a Wikipedia entry.
		*/
	//	Used in: Annotations.dataSources.wikipedia.postProcessReferenceEntry
	extraneousElementSelectors: [
		"style",
		".mw-ref",
		".shortdescription",
		"td hr",
		".hatnote",
		".portal",
		".penicon",
		".reference",
		".Template-Fact",
		".error",
		".mwe-math-mathml-inline",
        ".sidebar",
        ".ambox",
		".unicode.haudio"
	],

	/*  CSS properties to preserve when stripping inline styles.
		*/
	//	Used in: Annotations.dataSources.wikipedia.postProcessReferenceEntry
	preservedInlineStyleProperties: [
		"display",
		"position",
		"top",
		"left",
		"bottom",
		"right",
		"width",
		"height",
		"word-break"
	],

	/*  Post-process an already-constructed annotation created from a Wikipedia
		entry (do HTML cleanup, etc.).
		*/
	//	Called by: Annotations.dataSources.wikipedia.referenceDataFromParsedAPIResponse
	postProcessReferenceEntry: (referenceEntry, identifier) => {
		let articleURL = new URL(identifier);

		//  Remove unwanted elements.
		referenceEntry.querySelectorAll(Annotations.dataSources.wikipedia.extraneousElementSelectors.join(", ")).forEach(element => {
			element.remove();
		});

		//  Remove location maps (they don’t work right).
		referenceEntry.querySelectorAll(".locmap").forEach(locmap => {
			locmap.closest("tr").remove();
		});

		//	Remove other maps.
		referenceEntry.querySelectorAll("img").forEach(image => {
			let imageSourceURL = new URL(image.src);
			if (imageSourceURL.hostname == "maps.wikimedia.org")
				image.remove();
		});

		//  Remove empty paragraphs.
		referenceEntry.querySelectorAll("p:empty").forEach(emptyGraf => {
			emptyGraf.remove();
		});

		//	Remove edit-links.
		referenceEntry.querySelectorAll("a[title^='Edit this on Wiki'], a[title^='Edit this at Wiki']").forEach(editLink => {
			editLink.remove();
		});

		//  Process links.
		referenceEntry.querySelectorAll("a").forEach(link => {
			//	De-linkify non-anchor self-links.
			if (   link.hash     == ""
				&& link.pathname == articleURL.pathname) {
				unwrap(link);
				return;
			}

			//  Qualify links.
			if (link.getAttribute("href").startsWith("#"))
				link.pathname = articleURL.pathname;
			if (link.hostname == location.hostname)
				link.hostname = articleURL.hostname;

			//  Mark other Wikipedia links as also being annotated.
			if (/(.+?)\.wikipedia\.org/.test(link.hostname)) {
				if (Annotations.dataSources.wikipedia.matches(link)) {
					link.classList.add(Annotations.annotatedLinkFullClass);
				} else {
					if (!(   link.pathname.startsWithAnyOf(_π("/wiki/", [ "Special:" ]))
						  || link.pathname == "/w/index.php"))
						link.classList.add("link-live");
				}
			}

			//  Mark self-links (anchorlinks within the same article).
			if (link.pathname == articleURL.pathname)
				link.classList.add("link-self");
		});

		//	Strip inline styles and some related attributes.
		let tableElementsSelector = "table, thead, tfoot, tbody, tr, th, td";
		referenceEntry.querySelectorAll("[style]").forEach(styledElement => {
			//	Skip table elements; we handle those specially.
			if (styledElement.closest(tableElementsSelector) == styledElement)
				return;

			if (styledElement.style.display != "none")
				stripStyles(styledElement, null, Annotations.dataSources.wikipedia.preservedInlineStyleProperties);
		});
		//	Special handling for table elements.
		referenceEntry.querySelectorAll(tableElementsSelector).forEach(tableElement => {
			if (tableElement.style.display != "none")
				stripStyles(tableElement, null, [ "text-align" ]);

			tableElement.removeAttribute("width");
			tableElement.removeAttribute("height");
		});

		//  Rectify table classes.
		referenceEntry.querySelectorAll("table.sidebar").forEach(table => {
			table.classList.toggle("infobox", true);
		});

		//  Normalize table cell types.
		referenceEntry.querySelectorAll("th:not(:only-child)").forEach(cell => {
			let rowSpan = (cell.rowSpan > 1) ? ` rowspan="${cell.rowSpan}"` : ``;
			let colSpan = (cell.colSpan > 1) ? ` colspan="${cell.colSpan}"` : ``;
			cell.outerHTML = `<td${rowSpan}${colSpan}>${cell.innerHTML}</td>`;
		});

		//  Un-linkify images.
		referenceEntry.querySelectorAll("a img").forEach(imageLink => {
			imageLink.parentElement.outerHTML = imageLink.outerHTML;
		});

		//	Fix chemical formulas.
		referenceEntry.querySelectorAll(".chemf br").forEach(br => {
			br.remove();
		});

		//  Separate out the thumbnail and float it.
		let thumbnail = referenceEntry.querySelector("img");
		let thumbnailContainer;
		if (thumbnail)
			thumbnailContainer = thumbnail.closest(".infobox-image, .thumb");
		if (   thumbnail
			&& thumbnailContainer
			&& thumbnailContainer.closest(".gallery") == null) {
			while ([ "TR", "TD", "TH" ].includes(thumbnailContainer.tagName))
				thumbnailContainer = thumbnailContainer.parentElement;

			//	Save references to thumbnails’ parent elements.
			let thumbnailParents = [ ];

			//  Create the figure and move the thumbnail(s) into it.
			let figure = newElement("FIGURE", { "class": "float-right" });
			thumbnailContainer.querySelectorAll(".infobox-image img, .thumb img").forEach(image => {
				if (image.closest("figure") == figure)
					return;

				thumbnailParents.push(image.parentElement);

				let closestRow = image.closest("tr, [style*='display']");
				while (!(closestRow.tagName == "TR" || closestRow.style.display == "table-row"))
					closestRow = closestRow.parentElement.closest("tr, [style*='display']");
				let allImagesInRow = closestRow.querySelectorAll("img");
				if (allImagesInRow.length > 1) {
					let rowWrapper = newElement("SPAN", { "class": "image-wrapper image-row-wrapper" });
					rowWrapper.append(...allImagesInRow);
					figure.append(rowWrapper);
				} else {
					figure.append(allImagesInRow[0]);
				}
			});

			//  Create the caption, if need be.
			let caption = referenceEntry.querySelector(".mw-default-size + div, .infobox-caption");
			if (   caption
				&& caption.textContent > "")
				figure.appendChild(newElement("FIGCAPTION", null, { "innerHTML": caption.innerHTML }));

			//  Insert the figure as the first child of the annotation.
			referenceEntry.insertBefore(figure, referenceEntry.firstElementChild);

			//  Rectify classes.
			thumbnailParents.first.closest("table").classList.toggle("infobox", true);

			//  Remove the whole row where each thumbnail was.
			thumbnailParents.forEach(thumbnailParent => {
				thumbnailParent.closest("tr").remove();
			});
		} else if (   thumbnail
				   && thumbnail.closest("figure")) {
			let figure = thumbnail.closest("figure");

			//  Insert the figure as the first child of the annotation.
			referenceEntry.insertBefore(figure, referenceEntry.firstElementChild);
			figure.classList.add("float-right");

			let caption = figure.querySelector("figcaption");
			if (caption.textContent == "")
				caption.remove();
		}

		//	Rewrite other figures.
		referenceEntry.querySelectorAll("div.thumb").forEach(figureBlock => {
			let figure = newElement("FIGURE");
			figureBlock.querySelectorAll("img").forEach(image => {
				figure.appendChild(image);
			});
			figure.appendChild(newElement("FIGCAPTION", null, { "innerHTML": figureBlock.querySelector(".thumbcaption").innerHTML }));
			figureBlock.parentNode.insertBefore(figure, figureBlock);
			figureBlock.remove();
		});

		//	Mark certain images as not to be wrapped in figures.
		let noFigureImagesSelector = [
			".mwe-math-element",
			".mw-default-size",
			".sister-logo",
			".side-box-image",
			"p"
		].map(selector => `${selector} img`).join(", ");
		referenceEntry.querySelectorAll(noFigureImagesSelector).forEach(image => {
			image.classList.add("figure-not");
		});
	}
};

GW.notificationCenter.fireEvent("Annotations.didLoad");
