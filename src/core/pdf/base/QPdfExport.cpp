#include "QPdfExport.h"

#ifdef ENABLE_QPDF

#include <algorithm>
#include <sstream>  // for ostringstream
#include <string>   // for string
#include <unordered_set>
#include <vector>   // for vector

#include <qpdf/DLL.h>
#if QPDF_MAJOR_VERSION == 11
#define POINTERHOLDER_TRANSITION 4  // Only used for QPDF 11
#endif
#include <qpdf/QPDF.hh>
#include <qpdf/QPDFPageDocumentHelper.hh>
#include <qpdf/QPDFPageObjectHelper.hh>
#include <qpdf/QPDFWriter.hh>

#include "model/Document.h"   // for Document
#include "util/Assert.h"      // for xoj_assert
#include "util/Util.h"        // for npos
#include "util/i18n.h"        // for _
#include "util/safe_casts.h"  // for strict_cast

#include "config.h"      // for PROJECT_STRING
#include "filesystem.h"  // for path

QPdfExport::QPdfExport(const Document* doc, ProgressListener* progressListener):
        HybridPdfExport(doc, progressListener) {}

QPdfExport::~QPdfExport() = default;

static void reorderBackgrounds(QPDF& background, const std::vector<HybridPdfExport::OutputPageInfo>& outputPageInfos) {
    auto pageHelper = QPDFPageDocumentHelper(background);
    // We may need to shuffle the pages around: Remember the original pages addresses.
    auto backgroundPages = pageHelper.getAllPages();
    auto count = backgroundPages.size();
    // Count occurrences of background pages: the user might have duplicated or removed pages
    auto occurrences = HybridPdfExport::countOccurrences(count, outputPageInfos);

    size_t nbValidPages = 0;
    std::optional<QPDFPageObjectHelper> lastPageSet;
    for (size_t i = 0; i < outputPageInfos.size(); i++) {
        auto n = outputPageInfos[i].pdfBackgroundPageNumber;
        if (n != npos) {
#if QPDF_MAJOR_VERSION >= 11
            if (const auto& ps = background.getAllPages();
                !ps[nbValidPages].isSameObjectAs(backgroundPages[n].getObjectHandle())) {
#else
            {
                const auto& ps = background.getAllPages();
#endif
                if (nbValidPages > 0) {
                    auto prevPage = ps[nbValidPages - 1];
                    pageHelper.removePage(backgroundPages[n]);
                    pageHelper.addPageAt(backgroundPages[n], false, prevPage);
                } else {
                    pageHelper.removePage(backgroundPages[n]);
                    pageHelper.addPage(backgroundPages[n], true);
                }
            }
            if (occurrences[n].number >= 2) {
                // Keep a copy for next time
                backgroundPages[n].getObjectHandle().makeResourcesIndirect(background);
                backgroundPages[n] = backgroundPages[n].shallowCopyPage();
                pageHelper.addPage(backgroundPages[n], false);  // Append the copy
#if QPDF_MAJOR_VERSION >= 11
                xoj_assert(background.getAllPages().back().isSameObjectAs(backgroundPages[n].getObjectHandle()));
#endif
            }
            nbValidPages++;
            occurrences[n].number--;
        }
    }

    // The backgrounds are in place. Remove the unused backgrounds.
    auto pages = pageHelper.getAllPages();  // Makes a copy of the vector, so the iterators don't get invalidated
    for (auto it = std::next(pages.begin(), as_signed(nbValidPages)); it != pages.end(); it++) {
        pageHelper.removePage(*it);
    }
    xoj_assert(as_signed(background.getAllPages().size()) ==
               std::count_if(outputPageInfos.begin(), outputPageInfos.end(),
                             [](auto&& a) { return a.pdfBackgroundPageNumber != npos; }));
}

/*
 * The QPDF writer keeps every object reachable from the document catalog. When
 * pages have been removed from the page tree (partial export, duplicated or
 * reordered pages), outline entries, link annotations and named destinations
 * may still reference the removed pages, dragging their whole content (images,
 * fonts, metadata, ...) into the exported file. The helpers below remove those
 * dangling references so unexported pages are not retained.
 */

static std::string refKey(const QPDFObjectHandle& h) {
    auto og = h.getObjGen();
    return std::to_string(og.getObj()) + "," + std::to_string(og.getGen());
}

// Resolves the named destination against the catalog's /Dests dictionary.
static QPDFObjectHandle resolveNamedDest(QPDF& pdf, const std::string& name) {
    auto root = pdf.getRoot();
    if (root.hasKey("/Dests")) {
        auto dests = root.getKey("/Dests");
        if (dests.isDictionary() && dests.hasKey(name)) {
            auto dest = dests.getKey(name);
            if (dest.isDictionary() && dest.hasKey("/D")) {
                return dest.getKey("/D");
            }
            return dest;
        }
    }
    return QPDFObjectHandle();
}

// Returns the page object a GoTo destination in an outline item or annotation points to, or null.
static QPDFObjectHandle destinationPage(QPDF& pdf, const QPDFObjectHandle& dict) {
    QPDFObjectHandle dest;
    if (dict.hasKey("/Dest")) {
        dest = dict.getKey("/Dest");
    } else if (dict.hasKey("/A")) {
        auto action = dict.getKey("/A");
        if (action.isDictionary() && action.hasKey("/S") && action.getKey("/S").isName() &&
            action.getKey("/S").getName() == "/GoTo" && action.hasKey("/D")) {
            dest = action.getKey("/D");
        }
    }
    if (dest.isName() || dest.isString()) {
        dest = resolveNamedDest(pdf, dest.isName() ? dest.getName() : dest.getStringValue());
    }
    if (dest.isArray() && dest.getArrayNItems() > 0) {
        auto page = dest.getArrayItem(0);
        if (page.isPage()) {
            return page;
        }
    }
    return QPDFObjectHandle();
}

// Unlinks every outline item whose destination points to a removed page. Returns the number of
// remaining descendants of parent (for the /Count entries).
static int pruneOutlineItems(QPDF& pdf, QPDFObjectHandle& parent, const std::unordered_set<std::string>& kept) {
    if (!parent.hasKey("/First")) {
        return 0;
    }
    auto item = parent.getKey("/First");
    QPDFObjectHandle prev;
    int count = 0;
    while (!item.isNull()) {
        auto next = item.getKey("/Next");
        int childCount = pruneOutlineItems(pdf, item, kept);
        auto page = destinationPage(pdf, item);
        bool drop = !page.isNull() && !kept.count(refKey(page));
        if (drop) {
            if (!prev.isNull()) {
                if (next.isNull()) {
                    prev.removeKey("/Next");
                } else {
                    prev.replaceKey("/Next", next);
                }
            } else {
                if (next.isNull()) {
                    parent.removeKey("/First");
                } else {
                    parent.replaceKey("/First", next);
                }
            }
            if (!next.isNull()) {
                if (prev.isNull()) {
                    next.removeKey("/Prev");
                } else {
                    next.replaceKey("/Prev", prev);
                }
            }
        } else {
            count += 1 + childCount;
            if (childCount > 0) {
                item.replaceKey("/Count", QPDFObjectHandle::newInteger(childCount));
            } else {
                item.removeKey("/Count");
            }
            prev = item;
        }
        item = next;
    }
    if (prev.isNull()) {
        parent.removeKey("/First");
        parent.removeKey("/Last");
    } else {
        parent.replaceKey("/Last", prev);
    }
    return count;
}

static void pruneLinkAnnotations(QPDF& pdf, const std::unordered_set<std::string>& kept) {
    for (auto&& page: QPDFPageDocumentHelper(pdf).getAllPages()) {
        auto annots = page.getObjectHandle().getKey("/Annots");
        if (!annots.isArray()) {
            continue;
        }
        std::vector<QPDFObjectHandle> remaining;
        int n = annots.getArrayNItems();
        remaining.reserve(as_signed(n));
        for (int i = 0; i < n; i++) {
            auto annot = annots.getArrayItem(i);
            auto pageDest = annot.isDictionary() ? destinationPage(pdf, annot) : QPDFObjectHandle();
            if (!pageDest.isNull() && !kept.count(refKey(pageDest))) {
                continue;
            }
            remaining.push_back(annot);
        }
        if (static_cast<int>(remaining.size()) != n) {
            if (remaining.empty()) {
                page.getObjectHandle().removeKey("/Annots");
            } else {
                page.getObjectHandle().replaceKey("/Annots", QPDFObjectHandle::newArray(remaining));
            }
        }
    }
}

// Removes the entries of the catalog's /Dests dictionary whose target page has been removed.
static void pruneDestsDictionary(QPDF& pdf, const std::unordered_set<std::string>& kept) {
    auto root = pdf.getRoot();
    if (!root.hasKey("/Dests")) {
        return;
    }
    auto dests = root.getKey("/Dests");
    if (!dests.isDictionary()) {
        return;
    }
    for (auto&& [name, dest]: dests.getDictAsMap()) {
        auto page = destinationPage(pdf, dest);
        if (!page.isNull() && !kept.count(refKey(page))) {
            dests.removeKey(name);
        }
    }
}

static void pruneDanglingDestinations(QPDF& background) {
    std::unordered_set<std::string> kept;
    kept.reserve(QPDFPageDocumentHelper(background).getAllPages().size());
    for (auto&& p: QPDFPageDocumentHelper(background).getAllPages()) {
        kept.insert(refKey(p.getObjectHandle()));
    }

    auto root = background.getRoot();
    if (root.hasKey("/Outlines")) {
        auto outlines = root.getKey("/Outlines");
        if (outlines.isDictionary()) {
            pruneOutlineItems(background, outlines, kept);
            if (!outlines.hasKey("/First")) {
                root.removeKey("/Outlines");
            }
        }
    }

    pruneLinkAnnotations(background, kept);
    pruneDestsDictionary(background, kept);
}

bool QPdfExport::overlayAndSave(const fs::path& saveDestination, std::stringstream& overlaystream,
                                const std::vector<OutputPageInfo>& outputPageInfos) {
    try {
        auto overlaydata = overlaystream.str();  // Should probably be kept alive until we are done (not sure)
        QPDF overlay;
        overlay.processMemoryFile("overlay", overlaydata.data(), overlaydata.length());

        QPDF background;
        background.processFile(char_cast(doc->getPdfFilepath().u8string().c_str()));  // TODO: UTF8 is ok?

        reorderBackgrounds(background, outputPageInfos);

        // Prepare xobjects representing the pages in the overlay document
        std::vector<QPDFObjectHandle> overlaysAsXObjects;
        auto overlayPages = QPDFPageDocumentHelper(overlay).getAllPages();
        overlaysAsXObjects.reserve(overlayPages.size());
        for (auto&& p: overlayPages) {
            auto&& xobj = overlaysAsXObjects.emplace_back(p.getFormXObjectForPage());
            xobj.getDict().getKey("/Group").removeKey("/I");
        }

        auto outputPages = QPDFPageDocumentHelper(background).getAllPages();
        for (size_t n = 0, overlayPagesConsumed = 0; n < outputPageInfos.size(); n++) {
            auto [hasOverlay, bgIndex] = outputPageInfos[n];
            if (hasOverlay) {
                if (bgIndex != npos) {
                    auto page = QPDFPageObjectHelper(background.getAllPages()[n]);
                    // See qpdf/examples/pdf-overlay-page.cc

                    // Find a unique resource name for the new form XObject
                    QPDFObjectHandle resources = page.getAttribute("/Resources", true);
                    int min_suffix = 1;
                    std::string name = resources.getUniqueResourceName("/Fx", min_suffix);

                    auto localXObj = background.copyForeignObject(overlaysAsXObjects[overlayPagesConsumed]);

                    // Generate content to place the form XObject centered within destination page's trim box.
                    QPDFMatrix m;
                    std::string content =
                            page.placeFormXObject(localXObj, name, page.getCropBox().getArrayAsRectangle(), m);
                    if (!content.empty()) {
                        // Append the content to the page's content. Surround the original content with q...Q to
                        // the new content from the page's original content.
                        resources.mergeResources("<< /XObject << >> >>"_qpdf);
                        resources.getKey("/XObject").replaceKey(name, localXObj);
#if QPDF_MAJOR_VERSION > 11 || (QPDF_MAJOR_VERSION == 11 && QPDF_MINOR_VERSION >= 2)
                        page.addPageContents(background.newStream("q\n"), true);
                        page.addPageContents(background.newStream("\nQ\n" + content), false);
#else
                        page.addPageContents(QPDFObjectHandle::newStream(&background, "q\n"), true);
                        page.addPageContents(QPDFObjectHandle::newStream(&background, "\nQ\n" + content), false);
#endif
                    }
                } else {
                    // Simply insert the overlay as a page
                    if (n == 0) {
                        QPDFPageDocumentHelper(background).addPage(overlayPages[overlayPagesConsumed], true);
                    } else {
                        QPDFPageDocumentHelper(background)
                                .addPageAt(overlayPages[overlayPagesConsumed], false, background.getAllPages()[n - 1]);
                    }
                }
                overlayPagesConsumed++;
            }
        }

        auto info = [&]() {
            auto trailer = background.getTrailer();
            if (trailer.hasKey("/Info")) {
                return trailer.getKey("/Info");
            }
            auto info = QPDFObjectHandle::newDictionary();
            trailer.replaceKey("/Info", info);
            return info;
        }();

        auto replaceKey = [&](const char* key, const std::string& val) {
            QPDFObjectHandle str = info.newString(val);
            str.makeDirect();
            info.replaceKey(key, str);
        };

        replaceKey("/Producer", (std::string(PROJECT_STRING) + " + QPDF " + QPDF_VERSION));
        replaceKey("/ModDate", createPDFDateStringForNow());

        // Don't let dangling destinations retain the content of unexported pages
        pruneDanglingDestinations(background);

        QPDFWriter writer(background, char_cast(saveDestination.u8string().data()));  // is UTF8 ok?
        writer.write();
    } catch (const std::exception& e) {
        this->lastError = _("Error with overlay or final export:");
        this->lastError += std::string("\n") + e.what();
        return false;
    }
    return true;
}
#endif
