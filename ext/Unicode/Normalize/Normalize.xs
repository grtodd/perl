
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

/* These 5 files are prepared by mkheader */
#include "unfcmb.h"
#include "unfcan.h"
#include "unfcpt.h"
#include "unfcmp.h"
#include "unfexc.h"

/* Perl 5.6.1 ? */
#ifndef uvuni_to_utf8
#define uvuni_to_utf8   uv_to_utf8
#endif /* uvuni_to_utf8 */ 

/* Perl 5.6.1 ? */
#ifndef utf8n_to_uvchr
#define utf8n_to_uvchr  utf8_to_uv
#endif /* utf8n_to_uvchr */ 

/* At present, char > 0x10ffff are unaffected without complaint, right? */
#define VALID_UTF_MAX    (0x10ffff)
#define OVER_UTF_MAX(uv) (VALID_UTF_MAX < (uv))

/* HANGUL_H */
#define Hangul_SBase  0xAC00
#define Hangul_SFinal 0xD7A3
#define Hangul_SCount  11172

#define Hangul_NCount    588

#define Hangul_LBase  0x1100
#define Hangul_LFinal 0x1112
#define Hangul_LCount     19

#define Hangul_VBase  0x1161
#define Hangul_VFinal 0x1175
#define Hangul_VCount     21

#define Hangul_TBase  0x11A7
#define Hangul_TFinal 0x11C2
#define Hangul_TCount     28

#define Hangul_IsS(u)  ((Hangul_SBase <= (u)) && ((u) <= Hangul_SFinal))
#define Hangul_IsN(u)  (((u) - Hangul_SBase) % Hangul_TCount == 0)
#define Hangul_IsLV(u) (Hangul_IsS(u) && Hangul_IsN(u))
#define Hangul_IsL(u)  ((Hangul_LBase <= (u)) && ((u) <= Hangul_LFinal))
#define Hangul_IsV(u)  ((Hangul_VBase <= (u)) && ((u) <= Hangul_VFinal))
#define Hangul_IsT(u)  ((Hangul_TBase  < (u)) && ((u) <= Hangul_TFinal))
/* HANGUL_H */

/* this is used for canonical ordering of combining characters (c.c.). */
typedef struct {
    U8 cc;	/* combining class */
    UV uv;	/* codepoint */
    STRLEN pos; /* position */
} UNF_cc;

int compare_cc(const void *a, const void *b)
{
    int ret_cc;
    ret_cc = (*(UNF_cc*)a).cc - (*(UNF_cc*)b).cc;
    if(ret_cc) return ret_cc;
    return (*(UNF_cc*)a).pos - (*(UNF_cc*)b).pos;
}

U8* dec_canonical (UV uv)
{
    U8 ***plane, **row;
    if(OVER_UTF_MAX(uv)) return NULL;
    plane = (U8***)UNF_canon[uv >> 16];
    if(! plane) return NULL;
    row = plane[(uv >> 8) & 0xff];
    return row ? row[uv & 0xff] : NULL;
}

U8* dec_compat (UV uv)
{
    U8 ***plane, **row;
    if(OVER_UTF_MAX(uv)) return NULL;
    plane = (U8***)UNF_compat[uv >> 16];
    if(! plane) return NULL;
    row = plane[(uv >> 8) & 0xff];
    return row ? row[uv & 0xff] : NULL;
}

UV composite_uv (UV uv, UV uv2)
{
    UNF_complist ***plane, **row, *cell, *i;

    if(! uv2 || OVER_UTF_MAX(uv) || OVER_UTF_MAX(uv2)) return 0;

    if(Hangul_IsL(uv) && Hangul_IsV(uv2)) {
	uv  -= Hangul_LBase; /* lindex */
	uv2 -= Hangul_VBase; /* vindex */
	return(Hangul_SBase + (uv * Hangul_VCount + uv2) * Hangul_TCount);
    }
    if(Hangul_IsLV(uv) && Hangul_IsT(uv2)) {
	uv2 -= Hangul_TBase; /* tindex */
	return(uv + uv2);
    }
    plane = UNF_compos[uv >> 16];
    if(! plane) return 0;
    row = plane[(uv >> 8) & 0xff];
    if(! row)   return 0;
    cell = row[uv & 0xff];
    if(! cell)  return 0;
    for(i = cell; i->nextchar; i++) {
	if(uv2 == i->nextchar) return i->composite;
    }
    return 0;
}

U8 getCombinClass (UV uv)
{
    U8 **plane, *row;
    if(OVER_UTF_MAX(uv)) return 0;
    plane = (U8**)UNF_combin[uv >> 16];
    if(! plane) return 0;
    row = plane[(uv >> 8) & 0xff];
    return row ? row[uv & 0xff] : 0;
}

void sv_cat_decompHangul (SV* sv, UV uv)
{
    UV sindex, lindex, vindex, tindex;
    U8 *t, tmp[3 * UTF8_MAXLEN + 1];

    if(! Hangul_IsS(uv)) return;

    sindex =  uv - Hangul_SBase;
    lindex =  sindex / Hangul_NCount;
    vindex = (sindex % Hangul_NCount) / Hangul_TCount;
    tindex =  sindex % Hangul_TCount;

    t = tmp;
    t = uvuni_to_utf8(t, (lindex + Hangul_LBase));
    t = uvuni_to_utf8(t, (vindex + Hangul_VBase));
    if (tindex) t = uvuni_to_utf8(t, (tindex + Hangul_TBase));
    *t = '\0';
    sv_catpvn(sv, (char *)tmp, strlen((char *)tmp));
}

MODULE = Unicode::Normalize	PACKAGE = Unicode::Normalize

SV*
decompose(arg, compat)
    SV * arg
    SV * compat
  PROTOTYPE: $
  PREINIT:
    UV uv;
    SV *src, *dst;
    STRLEN srclen, retlen;
    U8 *s, *e, *p, *r;
    bool iscompat;
  CODE:
    if(SvUTF8(arg)) {
	src = arg;
    } else {
	src = sv_mortalcopy(arg);
	sv_utf8_upgrade(src);
    }
    iscompat = SvTRUE(compat);

    dst = newSV(1);
    (void)SvPOK_only(dst);
    SvUTF8_on(dst);

    s = (U8*)SvPV(src,srclen);
    e = s + srclen;
    for(p = s; p < e;){
	uv = utf8n_to_uvchr(p, e - p, &retlen, 0);
	p += retlen;
	if(Hangul_IsS(uv)) sv_cat_decompHangul(dst, uv);
	else {
	    r = iscompat ? dec_compat(uv) : dec_canonical(uv);
	    if(r) sv_catpv(dst, (char *)r);
	    else  sv_catpvn(dst, (char *)p - retlen, retlen);
	}
    }
    RETVAL = dst;
  OUTPUT:
    RETVAL



SV*
reorder(arg)
    SV * arg
  PROTOTYPE: $
  PREINIT:
    SV *src;
    STRLEN srclen, retlen, stk_cc_max;
    U8 *s, *e, *p, curCC;
    UV uv;
    UNF_cc * stk_cc;
  CODE:
    src = newSVsv(arg);
    if(! SvUTF8(arg)) sv_utf8_upgrade(src);

    stk_cc_max = 10; /* enough as an initial value? */
    New(0, stk_cc, stk_cc_max, UNF_cc);

    s = (U8*)SvPV(src,srclen);
    e = s + srclen;

    for(p = s; p < e;){
	U8 *cc_in;
	STRLEN cc_len, cc_iter, cc_pos;

	uv = utf8n_to_uvchr(p, e - p, &retlen, 0);
	curCC = getCombinClass(uv);
	p += retlen;

	if(! (curCC && p < e)) continue; else cc_in = p - retlen;

	cc_pos = 0;
	stk_cc[cc_pos].cc  = curCC;
	stk_cc[cc_pos].uv  = uv;
	stk_cc[cc_pos].pos = cc_pos;

	while(p < e) {
	    uv = utf8n_to_uvchr(p, e - p, &retlen, 0);
	    curCC = getCombinClass(uv);
	    if(!curCC) break;
	    p += retlen;
	    cc_pos++;
	    if(stk_cc_max <= cc_pos) { /* extend if need */
		stk_cc_max = cc_pos + 1;
		Renew(stk_cc, stk_cc_max, UNF_cc);
	    }
	    stk_cc[cc_pos].cc  = curCC;
	    stk_cc[cc_pos].uv  = uv;
	    stk_cc[cc_pos].pos = cc_pos;
	}

	 /* only one c.c. in cc_len from cc_in, no need of reordering */
	if(!cc_pos) continue;

	qsort((void*)stk_cc, cc_pos + 1, sizeof(UNF_cc), compare_cc);

	cc_len = p - cc_in;
	p = cc_in;
	for(cc_iter = 0; cc_iter <= cc_pos; cc_iter++) {
	    p = uvuni_to_utf8(p, stk_cc[cc_iter].uv);
	}
    }
    Safefree(stk_cc);
    RETVAL = src;
  OUTPUT:
    RETVAL



SV*
compose(arg)
    SV * arg
  PROTOTYPE: $
  PREINIT:
    SV  *src, *dst, *tmp;
    U8  *s, *p, *e, *d, *t, *tmp_start, curCC, preCC;
    UV uv, uvS, uvComp;
    STRLEN srclen, dstlen, tmplen, retlen;
    bool beginning = TRUE;
  CODE:
    if(SvUTF8(arg)) {
	src = arg;
    } else {
	src = sv_mortalcopy(arg);
	sv_utf8_upgrade(src);
    }

    s = (U8*)SvPV(src, srclen);
    e = s + srclen;
    dstlen = srclen + 1; /* equal or shorter, XXX */
    dst = newSV(dstlen);
    (void)SvPOK_only(dst);
    SvUTF8_on(dst);
    d = (U8*)SvPVX(dst);

  /* for uncomposed combining char */
    tmp = sv_2mortal(newSV(dstlen));
    (void)SvPOK_only(tmp);
    SvUTF8_on(tmp);

    for(p = s; p < e;){
	if(beginning) {
	    uvS = utf8n_to_uvchr(p, e - p, &retlen, 0);
	    p += retlen;

            if (getCombinClass(uvS)){ /* no Starter found yet */
		d = uvuni_to_utf8(d, uvS);
		continue;
	    }
            beginning = FALSE;
	}

    /* Starter */
	t = tmp_start = (U8*)SvPVX(tmp);
	preCC = 0;

    /* to the next Starter */
	while(p < e) {
	    uv = utf8n_to_uvchr(p, e - p, &retlen, 0);
	    p += retlen;
	    curCC = getCombinClass(uv);

	    if(preCC && preCC == curCC) {
		preCC = curCC;
		t = uvuni_to_utf8(t, uv);
	    } else {
		uvComp = composite_uv(uvS, uv);

	/* S + C + S => S-S + C would be also blocked. */
		if( uvComp && ! isExclusion(uvComp) && preCC <= curCC)
		{
		    /* preCC not changed to curCC */
		    uvS = uvComp;
	        } else if (! curCC && p < e) { /* blocked */
		    break;
		} else {
		    preCC = curCC;
		    t = uvuni_to_utf8(t, uv);
		}
	    }
	}
	d = uvuni_to_utf8(d, uvS); /* starter (composed or not) */
	if(tmplen = t - tmp_start) { /* uncomposed combining char */
	    t = (U8*)SvPVX(tmp);
	    while(tmplen--) *d++ = *t++;
	}
	uvS = uv;
    } /* for */
    e = d; /* end of dst */
    d = (U8*)SvPVX(dst);
    SvCUR_set(dst, e - d);
    RETVAL = dst;
  OUTPUT:
    RETVAL



U8
getCombinClass(uv)
    UV uv

bool
isExclusion(uv)
    UV uv

SV*
getComposite(uv, uv2)
    UV uv
    UV uv2
  PROTOTYPE: $$
  PREINIT:
    UV comp;
  CODE:
    comp = composite_uv(uv, uv2);
    RETVAL = comp ? newSVuv(comp) : &PL_sv_undef;
  OUTPUT:
    RETVAL

SV*
getCanon(uv)
    UV uv
  PROTOTYPE: $
  ALIAS:
    getCompat = 1
  PREINIT:
    U8 * rstr;
  CODE:
    if(Hangul_IsS(uv)) {
	SV * dst;
	dst = newSV(1);
	(void)SvPOK_only(dst);
	sv_cat_decompHangul(dst, uv);
	RETVAL = dst;
    } else {
	rstr = ix ? dec_compat(uv) : dec_canonical(uv);
	if(!rstr) XSRETURN_UNDEF;
	RETVAL = newSVpvn((char *)rstr, strlen((char *)rstr));
    }
    SvUTF8_on(RETVAL);
  OUTPUT:
    RETVAL

