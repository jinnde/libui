// 6 september 2015
#import "uipriv_darwin.h"

// TODO
#define complain(...) implbug(__VA_ARGS__)

// TODO double-check that we are properly handling allocation failures (or just toll free bridge from cocoa)
struct uiDrawFontFamilies {
	CFArrayRef fonts;
};

uiDrawFontFamilies *uiDrawListFontFamilies(void)
{
	uiDrawFontFamilies *ff;

	ff = uiNew(uiDrawFontFamilies);
	ff->fonts = CTFontManagerCopyAvailableFontFamilyNames();
	if (ff->fonts == NULL)
		implbug("error getting available font names (no reason specified) (TODO)");
	return ff;
}

int uiDrawFontFamiliesNumFamilies(uiDrawFontFamilies *ff)
{
	return CFArrayGetCount(ff->fonts);
}

char *uiDrawFontFamiliesFamily(uiDrawFontFamilies *ff, int n)
{
	CFStringRef familystr;
	char *family;

	familystr = (CFStringRef) CFArrayGetValueAtIndex(ff->fonts, n);
	// toll-free bridge
	family = uiDarwinNSStringToText((NSString *) familystr);
	// Get Rule means we do not free familystr
	return family;
}

void uiDrawFreeFontFamilies(uiDrawFontFamilies *ff)
{
	CFRelease(ff->fonts);
	uiFree(ff);
}

struct uiDrawTextFont {
	CTFontRef f;
};

uiDrawTextFont *mkTextFont(CTFontRef f, BOOL retain)
{
	uiDrawTextFont *font;

	font = uiNew(uiDrawTextFont);
	font->f = f;
	if (retain)
		CFRetain(font->f);
	return font;
}

uiDrawTextFont *mkTextFontFromNSFont(NSFont *f)
{
	// toll-free bridging; we do retain, though
	return mkTextFont((CTFontRef) f, YES);
}

static CFMutableDictionaryRef newAttrList(void)
{
	CFMutableDictionaryRef attr;

	attr = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	if (attr == NULL)
		complain("error creating attribute dictionary in newAttrList()()");
	return attr;
}

static void addFontFamilyAttr(CFMutableDictionaryRef attr, const char *family)
{
	CFStringRef cfstr;

	cfstr = CFStringCreateWithCString(NULL, family, kCFStringEncodingUTF8);
	if (cfstr == NULL)
		complain("error creating font family name CFStringRef in addFontFamilyAttr()");
	CFDictionaryAddValue(attr, kCTFontFamilyNameAttribute, cfstr);
	CFRelease(cfstr);			// dictionary holds its own reference
}

static void addFontSizeAttr(CFMutableDictionaryRef attr, double size)
{
	CFNumberRef n;

	n = CFNumberCreate(NULL, kCFNumberDoubleType, &size);
	CFDictionaryAddValue(attr, kCTFontSizeAttribute, n);
	CFRelease(n);
}

#if 0
TODO
// See http://stackoverflow.com/questions/4810409/does-coretext-support-small-caps/4811371#4811371 and https://git.gnome.org/browse/pango/tree/pango/pangocoretext-fontmap.c for what these do
// And fortunately, unlike the traits (see below), unmatched features are simply ignored without affecting the other features :D
static void addFontSmallCapsAttr(CFMutableDictionaryRef attr)
{
	CFMutableArrayRef outerArray;
	CFMutableDictionaryRef innerDict;
	CFNumberRef numType, numSelector;
	int num;

	outerArray = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	if (outerArray == NULL)
		complain("error creating outer CFArray for adding small caps attributes in addFontSmallCapsAttr()");

	// Apple's headers say these are deprecated, but a few fonts still rely on them
	num = kLetterCaseType;
	numType = CFNumberCreate(NULL, kCFNumberIntType, &num);
	num = kSmallCapsSelector;
	numSelector = CFNumberCreate(NULL, kCFNumberIntType, &num);
	innerDict = newAttrList();
	CFDictionaryAddValue(innerDict, kCTFontFeatureTypeIdentifierKey, numType);
	CFRelease(numType);
	CFDictionaryAddValue(innerDict, kCTFontFeatureSelectorIdentifierKey, numSelector);
	CFRelease(numSelector);
	CFArrayAppendValue(outerArray, innerDict);
	CFRelease(innerDict);		// and likewise for CFArray

	// these are the non-deprecated versions of the above; some fonts have these instead
	num = kLowerCaseType;
	numType = CFNumberCreate(NULL, kCFNumberIntType, &num);
	num = kLowerCaseSmallCapsSelector;
	numSelector = CFNumberCreate(NULL, kCFNumberIntType, &num);
	innerDict = newAttrList();
	CFDictionaryAddValue(innerDict, kCTFontFeatureTypeIdentifierKey, numType);
	CFRelease(numType);
	CFDictionaryAddValue(innerDict, kCTFontFeatureSelectorIdentifierKey, numSelector);
	CFRelease(numSelector);
	CFArrayAppendValue(outerArray, innerDict);
	CFRelease(innerDict);		// and likewise for CFArray

	CFDictionaryAddValue(attr, kCTFontFeatureSettingsAttribute, outerArray);
	CFRelease(outerArray);
}
#endif

// Named constants for these were NOT added until 10.11, and even then they were added as external symbols instead of macros, so we can't use them directly :(
// kode54 got these for me before I had access to El Capitan; thanks to him.
#define ourNSFontWeightUltraLight -0.800000
#define ourNSFontWeightThin -0.600000
#define ourNSFontWeightLight -0.400000
#define ourNSFontWeightRegular 0.000000
#define ourNSFontWeightMedium 0.230000
#define ourNSFontWeightSemibold 0.300000
#define ourNSFontWeightBold 0.400000
#define ourNSFontWeightHeavy 0.560000
#define ourNSFontWeightBlack 0.620000

// Now remember what I said earlier about having to add the small caps traits after calling the above? This gets a dictionary back so we can do so.
CFMutableDictionaryRef extractAttributes(CTFontDescriptorRef desc)
{
	CFDictionaryRef dict;
	CFMutableDictionaryRef mdict;

	dict = CTFontDescriptorCopyAttributes(desc);
	// this might not be mutable, so make a mutable copy
	mdict = CFDictionaryCreateMutableCopy(NULL, 0, dict);
	CFRelease(dict);
	return mdict;
}

uiDrawTextFont *uiDrawLoadClosestFont(const uiDrawTextFontDescriptor *desc)
{
	CTFontRef f;
	CFMutableDictionaryRef attr;
	CTFontDescriptorRef cfdesc;

	attr = newAttrList();
	addFontFamilyAttr(attr, desc->Family);
	addFontSizeAttr(attr, desc->Size);

	// now we have to do the traits matching, so create a descriptor, match the traits, and then get the attributes back
	cfdesc = CTFontDescriptorCreateWithAttributes(attr);
	// TODO release attr?
	cfdesc = matchTraits(cfdesc, desc->Weight, desc->Italic, desc->Stretch);

	// specify the initial size again just to be safe
	f = CTFontCreateWithFontDescriptor(cfdesc, desc->Size, NULL);
	// TODO release cfdesc?

	return mkTextFont(f, NO);		// we hold the initial reference; no need to retain again
}

void uiDrawFreeTextFont(uiDrawTextFont *font)
{
	CFRelease(font->f);
	uiFree(font);
}

uintptr_t uiDrawTextFontHandle(uiDrawTextFont *font)
{
	return (uintptr_t) (font->f);
}

void uiDrawTextFontDescribe(uiDrawTextFont *font, uiDrawTextFontDescriptor *desc)
{
	// TODO
}

// text sizes and user space points are identical:
// - https://developer.apple.com/library/mac/documentation/TextFonts/Conceptual/CocoaTextArchitecture/TypoFeatures/TextSystemFeatures.html#//apple_ref/doc/uid/TP40009459-CH6-51627-BBCCHIFF text points are 72 per inch
// - https://developer.apple.com/library/mac/documentation/Cocoa/Conceptual/CocoaDrawingGuide/Transforms/Transforms.html#//apple_ref/doc/uid/TP40003290-CH204-SW5 user space points are 72 per inch
void uiDrawTextFontGetMetrics(uiDrawTextFont *font, uiDrawTextFontMetrics *metrics)
{
	metrics->Ascent = CTFontGetAscent(font->f);
	metrics->Descent = CTFontGetDescent(font->f);
	metrics->Leading = CTFontGetLeading(font->f);
	metrics->UnderlinePos = CTFontGetUnderlinePosition(font->f);
	metrics->UnderlineThickness = CTFontGetUnderlineThickness(font->f);
}

struct uiDrawTextLayout {
	CFMutableAttributedStringRef mas;
	CFRange *charsToRanges;
	double width;
};

uiDrawTextLayout *uiDrawNewTextLayout(const char *str, uiDrawTextFont *defaultFont, double width)
{
	uiDrawTextLayout *layout;
	CFAttributedStringRef immutable;
	CFMutableDictionaryRef attr;
	CFStringRef backing;
	CFIndex i, j, n;

	layout = uiNew(uiDrawTextLayout);

	// TODO docs say we need to use a different set of key callbacks
	// TODO see if the font attribute key callbacks need to be the same
	attr = newAttrList();
	// this will retain defaultFont->f; no need to worry
	CFDictionaryAddValue(attr, kCTFontAttributeName, defaultFont->f);

	immutable = CFAttributedStringCreate(NULL, (CFStringRef) [NSString stringWithUTF8String:str], attr);
	if (immutable == NULL)
		complain("error creating immutable attributed string in uiDrawNewTextLayout()");
	CFRelease(attr);

	layout->mas = CFAttributedStringCreateMutableCopy(NULL, 0, immutable);
	if (layout->mas == NULL)
		complain("error creating attributed string in uiDrawNewTextLayout()");
	CFRelease(immutable);

	uiDrawTextLayoutSetWidth(layout, width);

	// unfortunately the CFRanges for attributes expect UTF-16 codepoints
	// we want graphemes
	// fortunately CFStringGetRangeOfComposedCharactersAtIndex() is here for us
	// https://developer.apple.com/library/mac/documentation/Cocoa/Conceptual/Strings/Articles/stringsClusters.html says that this does work on all multi-codepoint graphemes (despite the name), and that this is the preferred function for this particular job anyway
	backing = CFAttributedStringGetString(layout->mas);
	n = CFStringGetLength(backing);
	// allocate one extra, just to be safe
	layout->charsToRanges = (CFRange *) uiAlloc((n + 1) * sizeof (CFRange), "CFRange[]");
	i = 0;
	j = 0;
	while (i < n) {
		CFRange range;

		range = CFStringGetRangeOfComposedCharactersAtIndex(backing, i);
		i = range.location + range.length;
		layout->charsToRanges[j] = range;
		j++;
	}
	// and set the last one
	layout->charsToRanges[j].location = i;
	layout->charsToRanges[j].length = 0;

	return layout;
}

void uiDrawFreeTextLayout(uiDrawTextLayout *layout)
{
	uiFree(layout->charsToRanges);
	CFRelease(layout->mas);
	uiFree(layout);
}

void uiDrawTextLayoutSetWidth(uiDrawTextLayout *layout, double width)
{
	layout->width = width;
}

struct framesetter {
	CTFramesetterRef fs;
	CFMutableDictionaryRef frameAttrib;
	CGSize extents;
};

// LONGTERM allow line separation and leading to be factored into a wrapping text layout

// TODO reconcile differences in character wrapping on platforms
void uiDrawTextLayoutExtents(uiDrawTextLayout *layout, double *width, double *height)
{
	struct framesetter fs;

	mkFramesetter(layout, &fs);
	*width = fs.extents.width;
	*height = fs.extents.height;
	freeFramesetter(&fs);
}

// Core Text doesn't draw onto a flipped view correctly; we have to do this
// see the iOS bits of the first example at https://developer.apple.com/library/mac/documentation/StringsTextFonts/Conceptual/CoreText_Programming/LayoutOperations/LayoutOperations.html#//apple_ref/doc/uid/TP40005533-CH12-SW1 (iOS is naturally flipped)
// TODO how is this affected by the CTM?
static void prepareContextForText(CGContextRef c, CGFloat cheight, double *y)
{
	CGContextSaveGState(c);
	CGContextTranslateCTM(c, 0, cheight);
	CGContextScaleCTM(c, 1.0, -1.0);
	CGContextSetTextMatrix(c, CGAffineTransformIdentity);

	// wait, that's not enough; we need to offset y values to account for our new flipping
	*y = cheight - *y;
}

// TODO placement is incorrect for Helvetica
void doDrawText(CGContextRef c, CGFloat cheight, double x, double y, uiDrawTextLayout *layout)
{
	struct framesetter fs;
	CGRect rect;
	CGPathRef path;
	CTFrameRef frame;

	prepareContextForText(c, cheight, &y);
	mkFramesetter(layout, &fs);

	// oh, and since we're flipped, y is the bottom-left coordinate of the rectangle, not the top-left
	// since we are flipped, we subtract
	y -= fs.extents.height;

	rect.origin = CGPointMake(x, y);
	rect.size = fs.extents;
	path = CGPathCreateWithRect(rect, NULL);

	frame = CTFramesetterCreateFrame(fs.fs,
		CFRangeMake(0, 0),
		path,
		fs.frameAttrib);
	if (frame == NULL)
		complain("error creating CTFrame object in doDrawText()");
	CTFrameDraw(frame, c);
	CFRelease(frame);

	CFRelease(path);

	freeFramesetter(&fs);
	CGContextRestoreGState(c);
}

// LONGTERM provide an equivalent to CTLineGetTypographicBounds() on uiDrawTextLayout?

// LONGTERM keep this for later features and documentation purposes
#if 0
		w = CTLineGetTypographicBounds(line, &ascent, &descent, NULL);
		// though CTLineGetTypographicBounds() returns 0 on error, it also returns 0 on an empty string, so we can't reasonably check for error
		CFRelease(line);

	// LONGTERM provide a way to get the image bounds as a separate function later
	bounds = CTLineGetImageBounds(line, c);
	// though CTLineGetImageBounds() returns CGRectNull on error, it also returns CGRectNull on an empty string, so we can't reasonably check for error

	// CGContextSetTextPosition() positions at the baseline in the case of CTLineDraw(); we need the top-left corner instead
	CTLineGetTypographicBounds(line, &yoff, NULL, NULL);
	// remember that we're flipped, so we subtract
	y -= yoff;
	CGContextSetTextPosition(c, x, y);
#endif

static CFRange charsToRange(uiDrawTextLayout *layout, int startChar, int endChar)
{
	CFRange start, end;
	CFRange out;

	start = layout->charsToRanges[startChar];
	end = layout->charsToRanges[endChar];
	out.location = start.location;
	out.length = end.location - start.location;
	return out;
}

#define rangeToCFRange() charsToRange(layout, startChar, endChar)

void uiDrawTextLayoutSetColor(uiDrawTextLayout *layout, int startChar, int endChar, double r, double g, double b, double a)
{
	CGColorSpaceRef colorspace;
	CGFloat components[4];
	CGColorRef color;

	// for consistency with windows, use sRGB
	colorspace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	components[0] = r;
	components[1] = g;
	components[2] = b;
	components[3] = a;
	color = CGColorCreate(colorspace, components);
	CGColorSpaceRelease(colorspace);

	CFAttributedStringSetAttribute(layout->mas,
		rangeToCFRange(),
		kCTForegroundColorAttributeName,
		color);
	CGColorRelease(color);		// TODO safe?
}
