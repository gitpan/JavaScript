#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#ifdef INCLUDES_IN_SMJS

#include <smjs/jsapi.h>
#include <smjs/jsdbgapi.h>
#include <smjs/jsinterp.h>
#include <smjs/jsfun.h>
#include <smjs/jsobj.h>
#include <smjs/jsprf.h>
#include <smjs/jsscope.h>

#else

#ifdef INCLUDES_IN_MOZJS

#include <mozjs/jsapi.h>
#include <mozjs/jsdbgapi.h>
#include <mozjs/jsinterp.h>
#include <mozjs/jsfun.h>
#include <mozjs/jsobj.h>
#include <mozjs/jsprf.h>
#include <mozjs/jsscope.h>

#else

#include <jsapi.h>
#include <jsdbgapi.h>
#include <jsinterp.h>
#include <jsfun.h>
#include <jsobj.h>
#include <jsprf.h>
#include <jsscope.h>

#endif

#endif

#define _IS_UNDEF(a) (SvANY(a) == SvANY(&PL_sv_undef))

/* Define macros to handle JS_GetClass in safe and non-safe thread spidermonkeys */
#ifdef JS_THREADSAFE
#define PJS_GET_CLASS(cx,obj) JS_GetClass(cx,obj)
#else
#define PJS_GET_CLASS(cx,obj) JS_GetClass(obj)
#endif

#define PJS_GET_CONTEXT(cx) (PJS_Context *) JS_GetContextPrivate(cx)

/* Defines */

#define PJS_ERROR_PACKAGE     "JavaScript::Error"
#define PJS_FUNCTION_PACKAGE  "JavaScript::Function"
#define PJS_BOXED_PACKAGE     "JavaScript::Boxed"

#define PJS_INSTANCE_METHOD   0
#define PJS_CLASS_METHOD      1

#define PJS_PROP_PRIVATE      0x1
#define PJS_PROP_READONLY     0x2
#define PJS_PROP_ACCESSOR     0x4
#define PJS_CLASS_NO_INSTANCE 0x1

/* Global class, does nothing */
static JSClass global_class = {
    "global", 0,
    JS_PropertyStub,  JS_PropertyStub,  JS_PropertyStub,  JS_PropertyStub,
    JS_EnumerateStub, JS_ResolveStub,   JS_ConvertStub,   JS_FinalizeStub,
    JSCLASS_NO_OPTIONAL_MEMBERS
};

/* Structures needed for callbacks */
/* If next is NULL, then the instance is the last in order */

struct PJS_Function {
    /* The name of the JavaScript function which this perl function is bound to */
    char *name;
    /* The perl reference to the function */
    SV *callback;
    /* Next function in list */
    struct PJS_Function	*_next;
};

typedef struct PJS_Function PJS_Function;

struct PJS_Property {
    int8 tinyid;
    
    SV *getter;    /* these are coderefs! */
    SV *setter;

    struct PJS_Property	*_next;
};

typedef struct PJS_Property PJS_Property;

struct PJS_Class {
    /* Clasp */
    JSClass *clasp;

    /* Package name in Perl */
    char *pkg;
      
    /* Reference to Perl subroutine that returns an instance of the object */
    SV *cons;

    /* Reference to prototype object */
    JSObject *proto;

    /* Linked list of methods bound to class */
    PJS_Function *methods;
    JSFunctionSpec *fs;
    JSFunctionSpec *static_fs;
    
    /* Linked list of properties bound to class */
    int8 next_property_id;
    PJS_Property *properties;
    JSPropertySpec *ps;
    JSPropertySpec *static_ps;

    /* Flags such as JS_CLASS_NO_INSTANCE */
    I32 flags;

    struct PJS_Class *_next;    
};

typedef struct PJS_Class PJS_Class;

/* Strucuture that keeps track of contexts */
struct PJS_Context {
    /* The JavaScript context which this instance belongs to */
    JSContext *cx;

    /* Pointer to the first callback item that is registered */
    PJS_Function *functions;

    /* Pointer to the first bound class */
    PJS_Class *classes;

    struct PJS_Context *next;		/* Pointer to the next created context */
    struct PJS_Runtime *rt;

    /* Set to a SVt_PVCV if we have an error handler */
    SV *error_handler;

    /* Set to a SVt_PVCV if we have an branch handler */
    SV *branch_handler;
};

typedef struct PJS_Context PJS_Context;

struct PJS_Runtime {
    JSRuntime *rt;
    PJS_Context	*list;
    SV *interrupt_handler;
};

typedef struct PJS_Runtime PJS_Runtime;

/* Structure that keeps precompiled strict */
struct PJS_Script {
    PJS_Context *cx;
    JSScript *script;
};

typedef struct PJS_Script PJS_Script;

static void PJS_finalize(JSContext *, JSObject *);

/* PJS_Context functions */
static PJS_Class *PJS_get_class_by_name(PJS_Context *, const char *);
static PJS_Class *PJS_get_class_by_package(PJS_Context *, const char *);
static void PJS_bind_function(PJS_Context *, const char *, SV *);
static void PJS_free_context(PJS_Context *);

/* PJS_Function functions */
static void PJS_free_function(PJS_Function *);

/* PJS_Class functions */
static void PJS_free_class(PJS_Class *);

/* PJS_Property functions */
static void PJS_free_property(PJS_Property *);

static SV* JSHASHToSV(JSContext *, HV *, JSObject *);
static SV* JSARRToSV(JSContext *, HV *, JSObject *);

static JSBool JSVALToSV(JSContext *, HV *, jsval, SV **);
static JSBool SVToJSVAL_real(JSContext *, JSObject *, SV *, jsval *, int);

/* Callbacks */
static JSBool PJS_invoke_perl_function(JSContext *, JSObject *, uintN, jsval *, jsval *);
static JSBool PJS_invoke_perl_object_method(JSContext *, JSObject *, uintN, jsval *, jsval *);
static JSBool PJS_invoke_perl_property_getter(JSContext *cx, JSObject *, jsval, jsval *);
static JSBool PJS_invoke_perl_property_setter(JSContext *cx, JSObject *, jsval, jsval *);                

#define SVToJSVAL(cx,obj,ref,rval)        SVToJSVAL_real(cx,obj,ref,rval,0)
#define SVToJSVAL_nofunc(cx,obj,ref,rval) SVToJSVAL_real(cx,obj,ref,rval,1)

#define JSFUN_SELF JS_ValueToFunction(cx, argv[-2])
#define JSFUN_PARENT (JSObject *) JSVAL_TO_OBJECT(argv[-1])

/* caller by runtime between ops */
static JSTrapStatus PJS_interrupt_handler(JSContext *cx, JSScript *script, jsbytecode *pc, jsval *rval, void *closure) {
    dSP;
    PJS_Runtime *rt = (PJS_Runtime *) closure;
    PJS_Context *pcx = PJS_GET_CONTEXT(cx);
    SV *scx, *rv;
    int rc;
    JSTrapStatus status = JSTRAP_CONTINUE;
    
    if (rt->interrupt_handler) {
        ENTER ;
        SAVETMPS ;
        PUSHMARK(SP) ;

	scx = sv_newmortal();
	sv_setref_pv(scx, Nullch, (void*) pcx);
        
        XPUSHs(scx);
        XPUSHs(newSViv(*pc));
        
        PUTBACK;
        
        rc = perl_call_sv(SvRV(rt->interrupt_handler), G_SCALAR | G_EVAL);

        SPAGAIN;

        rv = POPs;

        if (!SvTRUE(rv)) {
            status = JSTRAP_ERROR;
        }

        if (SvTRUE(ERRSV)) {
            sv_setsv(ERRSV, &PL_sv_undef);
        }
        
        PUTBACK;

        FREETMPS;
        LEAVE;
    }
   
    return status;
}

/* Called by context when we encounter an error */
static void PJS_error_handler(JSContext *cx, const char *message, JSErrorReport *report) {
    dSP;

    PJS_Context *context;
    
    context = PJS_GET_CONTEXT(cx);

    if (context != NULL && context->error_handler) {
        ENTER ;
        SAVETMPS ;
        PUSHMARK(SP) ;
        XPUSHs(newSVpv(message, strlen(message)));
        XPUSHs(newSVpv(report->filename, strlen(report->filename)));
        XPUSHs(newSViv(report->lineno));
        XPUSHs(newSVpv(report->linebuf, strlen(report->linebuf)));
        PUTBACK;
        perl_call_sv(SvRV(context->error_handler), G_DISCARD | G_VOID | G_EVAL);
    }
}

/* Called by context when a branch occurs */
static JSBool PJS_branch_handler(JSContext *cx, JSScript *script) {
    dSP;

    PJS_Context *pcx;
    SV *rv;
    I32 rc = 0;
    JSBool status = JS_TRUE;
    
    pcx = PJS_GET_CONTEXT(cx);

    if (pcx != NULL && pcx->branch_handler) {
        ENTER ;
        SAVETMPS ;

        PUSHMARK(SP);
        
        rc = perl_call_sv(SvRV(pcx->branch_handler), G_SCALAR | G_EVAL);

        SPAGAIN;

        rv = POPs;

        if (!SvTRUE(rv)) {
            status = JS_FALSE;
        }

        if (SvTRUE(ERRSV)) {
            sv_setsv(ERRSV, &PL_sv_undef);
            status = JS_FALSE;
        }
        
        PUTBACK;

        FREETMPS;
        LEAVE;
    }

    return status;
}

static PJS_Function *PJS_get_function(PJS_Context *cx, const char *name) {
    PJS_Function *function;

    function = cx->functions;

    while(function != NULL) {
        if(strcmp(function->name, name) == 0) {
            return function;
        }
        
        function = function->_next;
    }

    return NULL;
}

static PJS_Class *PJS_get_class_by_name(PJS_Context *cx, const char *name) {
    PJS_Class *cls = NULL;
    
    cls = cx->classes;
    
    while(cls != NULL) {
        if(strcmp(cls->clasp->name, name) == 0) {
            return cls;
        }
        
        cls = cls->_next;
    }
    
    return NULL;
}

static PJS_Class *PJS_get_class_by_package(PJS_Context *cx, const char *pkg) {
    PJS_Class *cls = NULL;
    
    cls = cx->classes;

    while(cls != NULL) {
        if(cls->pkg != NULL &&
           strcmp(cls->pkg, pkg) == 0) {
            return cls;
        }
        
        cls = cls->_next;
    }
    
    return NULL;
}

static PJS_Function *PJS_get_method_by_name(PJS_Class *cls, const char *name) {
    PJS_Function *ret;
    
    ret = cls->methods;

    while(ret != NULL) {
        if(strcmp(ret->name, name) == 0) {
            return ret;
        }
        
        ret = ret->_next;
    }
    
    return NULL;
}

static PJS_Property *PJS_get_property_by_id(PJS_Class *pcls, int8 tinyid) {
    PJS_Property *prop;
    
    prop = pcls->properties;
    
    while(prop != NULL) {
        if (prop->tinyid == tinyid) {
            return prop;
        }
        
        prop = prop->_next;
    }
    
    return NULL;
}

static void PJS_report_exception(PJS_Context *pcx) {
    jsval val;
    JSObject *object;

    /* If ERRSV is already set we can just return */
    if (SvTRUE(ERRSV)) {
        return;
    }
    
    /* No need to report exception if there isn't one */
    if (JS_IsExceptionPending(pcx->cx) == JS_FALSE) {
        return;
    }

    JS_GetPendingException(pcx->cx, &val);
    if (JSVALToSV(pcx->cx, NULL, val, &ERRSV) == JS_FALSE) {
        croak("Failed to convert error object to perl object");
    }

    JS_ClearPendingException(pcx->cx);
    
    /* convert internal JS parser exceptions into JavaScript::Error objects. */
    if (JSVAL_IS_OBJECT(val)) {
        JS_ValueToObject(pcx->cx, val, &object);
        if (strcmp(OBJ_GET_CLASS(pcx->cx, object)->name, "Error") == 0) {
            sv_bless(ERRSV, gv_stashpvn(PJS_ERROR_PACKAGE, strlen(PJS_ERROR_PACKAGE), TRUE));
        }
    }
}

static SV *PJS_call_perl_method(const char *method, ...) {
    dSP;
    va_list ap;
    SV *arg, *ret = sv_newmortal();
    int rcount;

    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    va_start(ap, method);
    while ((arg = va_arg(ap, SV*)) != NULL) {
        XPUSHs(arg);
    }

    PUTBACK;

    rcount = perl_call_method(method, G_SCALAR);

    SPAGAIN;

    sv_setsv(ret, POPs);

    PUTBACK;
    FREETMPS;
    LEAVE;

    return ret;
}

static I32 perl_call_sv_with_jsvals_rsv(JSContext *cx, JSObject *obj, SV *code, SV *caller, uintN argc, jsval *argv, SV **rsv) {
    dSP;
    I32 rcount = 0;
    int arg;
    
    if (SvROK(code) && SvTYPE(SvRV(code)) == SVt_PVCV) {
        ENTER ;
        SAVETMPS ;
        PUSHMARK(SP) ;
        
        if (caller) {
            XPUSHs(caller);
        }
        
        for (arg = 0; arg < argc; arg++) {
            SV *sv = sv_newmortal();
            JSVALToSV(cx, NULL, argv[arg], &sv);
            XPUSHs(sv);
        }
        
        PUTBACK ;
        
        rcount = perl_call_sv(SvRV(code), G_SCALAR|G_EVAL);
        
        SPAGAIN ;
        
        if(rcount) {
            int i;
            /* XXX: this is wrong */
            for (i = 0; i < rcount; ++i) {
                if (rsv) {
                    *rsv = POPs;
                    SvREFCNT_inc(*rsv);
                }
            }
        }
        else {
        }

        if (SvTRUE(ERRSV)) {
            jsval rval;
            SV* cp = sv_mortalcopy( ERRSV );
            if (SVToJSVAL(cx, obj, cp, &rval) != JS_FALSE) {
                JS_SetPendingException(cx, rval);
                rcount = -1;
            }
            else {
                croak("Can't convert perl error into JSVAL");
            }
        }
        
        PUTBACK ;
        FREETMPS ;
        LEAVE ;
    }
    else {
        warn("not a coderef");
    }
    
    return rcount;
}

static I32 perl_call_sv_with_jsvals(JSContext *cx, JSObject *obj, SV *code, SV *caller, uintN argc, jsval *argv, jsval *rval) {
    SV *rsv;
    I32 rcount = perl_call_sv_with_jsvals_rsv(cx, obj, code, caller, argc, argv, rval ? &rsv : NULL);
    
    if (rval) {
        SVToJSVAL(cx, obj, rsv, rval);
    }
    
    return rcount;
}

static JSBool PJS_call_javascript_function(PJS_Context *pcx, jsval func, SV *args, jsval *rval) {
    jsval *arg_list;
    jsval *context;
    SV *val;
    AV *av;
    int arg_count, i;

    /* Clear $@ */
    sv_setsv(ERRSV, &PL_sv_undef);

    av = (AV *) SvRV(args);
    arg_count = av_len(av);

    Newz(1, arg_list, arg_count + 1, jsval);
    if (arg_list == NULL) {
        croak("Failed to allocate memory for argument list");
    }

    for (i = 0; i <= arg_count; i++) {
        val = *av_fetch(av, i, 0);

        if (SVToJSVAL(pcx->cx, JS_GetGlobalObject(pcx->cx), val, &(arg_list[i])) == JS_FALSE) {
            Safefree(arg_list);
            croak("Can't convert argument number %d to jsval", i);
        }
    }

    if (js_InternalCall(pcx->cx, JS_GetGlobalObject(pcx->cx), func,
                        arg_count + 1, (jsval *) arg_list, (jsval *) rval) == JS_FALSE) {
        PJS_report_exception(pcx);
        return JS_FALSE;
    }

    return JS_TRUE;
}

static JSBool perl_call_jsfunc(JSContext *cx, JSObject *obj, uintN argc, jsval *argv, jsval *rval) {
    jsval tmp;
    SV *code;
    JSFunction *jsfun = JSFUN_SELF;
    JSObject *funobj = JS_GetFunctionObject(jsfun);

    if (JS_GetProperty(cx, funobj, "_perl_func", &tmp) == JS_FALSE) {
        croak("Can't get coderef\n");
    }
    
    code = JSVAL_TO_PRIVATE(tmp);
    if (perl_call_sv_with_jsvals(cx, obj, code, NULL, argc, argv, rval) < 0) {
        return JS_FALSE;
    }
    
    return JS_TRUE;
    
}

/* Universal call back for functions */
static JSBool PJS_invoke_perl_function(JSContext *cx, JSObject *obj, uintN argc, jsval *argv, jsval *rval) {
    PJS_Function *callback;
    PJS_Context *context;
    JSFunction *fun = JSFUN_SELF;

    if (!(context = PJS_GET_CONTEXT(cx))) {
        croak("Can't get context\n");
    }

    if (!(callback = PJS_get_function(context, (const char *) JS_GetFunctionName(fun)))) {
        croak("Couldn't find perl callback");
    }
    
    if (perl_call_sv_with_jsvals(cx, obj, callback->callback, NULL, argc, argv, rval) < 0) {
        return JS_FALSE;
    }

    return JS_TRUE;
}

static void PJS_finalize(JSContext *cx, JSObject *obj) {
    void *ptr = JS_GetPrivate(cx, obj);

    if(ptr != NULL) {
        SvREFCNT_dec((SV *) ptr);
    }
}

/* Universal call back for functions */
static JSBool PJS_construct_perl_object(JSContext *cx, JSObject *obj, uintN argc, jsval *argv, jsval *rval) {
    PJS_Class *pcls;
    PJS_Context *pcx;
    JSFunction *jfunc = JSFUN_SELF;
    char *name;
    
    if ((pcx = PJS_GET_CONTEXT(cx)) == NULL) {
        JS_ReportError(cx, "Can't find context %d", cx);
        return JS_FALSE;
    }

    name = (char *) JS_GetFunctionName(jfunc);
    
    if ((pcls = PJS_get_class_by_name(pcx, name)) == NULL) {
        JS_ReportError(cx, "Can't find class %s", name);
        return JS_FALSE;
    }

    /* Check if we are allowed to instanciate this class */
    if ((pcls->flags & PJS_CLASS_NO_INSTANCE)) {
        JS_ReportError(cx, "Class '%s' can't be instanciated", pcls->clasp->name);
        return JS_FALSE;
    }

    if (SvROK(pcls->cons)) {
        SV *rsv;
        SV *pkg = newSVpv(pcls->pkg, 0);
        perl_call_sv_with_jsvals_rsv(cx, obj,
                                     pcls->cons, pkg,
                                     argc, argv, &rsv);
        
        SvREFCNT_inc(rsv);
        
        JS_SetPrivate(cx, obj, (void *) rsv); 
    }

    return JS_TRUE;
}

static JSBool PJS_invoke_perl_object_method(JSContext *cx, JSObject *obj, uintN argc, jsval *argv, jsval *rval) {
    PJS_Context *pcx;
    PJS_Class *pcls;
    PJS_Function *pfunc;
    JSFunction *jfunc = JSFUN_SELF;
    JSClass *clasp;
    SV *caller;
    char *name;
    U8 invocation_mode;
    
    if((pcx = PJS_GET_CONTEXT(cx)) == NULL) {
        JS_ReportError(cx, "Can't find context %d", cx);
        return JS_FALSE;
    }

    if (JS_TypeOfValue(cx, OBJECT_TO_JSVAL(obj)) == JSTYPE_OBJECT) {
        /* Called as instsance */
        JSClass *clasp = PJS_GET_CLASS(cx, obj);
        name = (char *) clasp->name;
        invocation_mode = 1;
    }
    else {
        /* Called as static */
        JSFunction *parent_jfunc = JS_ValueToFunction(cx, OBJECT_TO_JSVAL(obj));
        if (parent_jfunc == NULL) {
            JS_ReportError(cx, "Failed to extract class for static property getter");
            return JS_FALSE;
        }
        name = (char *) JS_GetFunctionName(parent_jfunc);
        invocation_mode = 0;
    }

    if(!(pcls = PJS_get_class_by_name(pcx, name))) {
        JS_ReportError(cx, "Can't find class '%s'", name);
        return JS_FALSE;
    }

    name = (char *) JS_GetFunctionName(jfunc);

    if((pfunc = PJS_get_method_by_name(pcls, name)) == NULL) {
        JS_ReportError(cx, "Can't find method '%s' in '%s'", name, pcls->clasp->name);
        return JS_FALSE;
    }

    if (invocation_mode) {
        caller = (SV *) JS_GetPrivate(cx, obj);
    }
    else {
        caller = newSVpv(pcls->pkg, 0);
    }

    /* XXX: the original invocation here has slightly different
       retrun value handling.  if the returned value is reference
       same as priv, don't return it.  While the case is not
       covered by the tets */
    
    if (perl_call_sv_with_jsvals(cx, obj, pfunc->callback,
                                 caller, argc, argv, rval) < 0) {
        return JS_FALSE;
    }

    return JS_TRUE;
}

static JSBool PJS_invoke_perl_property_getter(JSContext *cx, JSObject *obj, jsval id, jsval *vp) {
    PJS_Context *pcx;
    PJS_Class *pcls;
    PJS_Property *pprop;
    SV *caller;
    char *name;
    jsint slot;
    U8 invocation_mode;

    if (!JSVAL_IS_INT(id)) {
        return JS_TRUE;
    }
    
    if((pcx = PJS_GET_CONTEXT(cx)) == NULL) {
        JS_ReportError(cx, "Can't find context %d", cx);
        return JS_FALSE;
    }

    if (JS_TypeOfValue(cx, OBJECT_TO_JSVAL(obj)) == JSTYPE_OBJECT) {
        /* Called as instsance */
        JSClass *clasp = PJS_GET_CLASS(cx, obj);
        name = (char *) clasp->name;
        invocation_mode = 1;
    }
    else {
        /* Called as static */
        JSFunction *parent_jfunc = JS_ValueToFunction(cx, OBJECT_TO_JSVAL(obj));
        if (parent_jfunc == NULL) {
            JS_ReportError(cx, "Failed to extract class for static property getter");
            return JS_FALSE;
        }
        name = (char *) JS_GetFunctionName(parent_jfunc);
        invocation_mode = 0;
    }
    
    if((pcls = PJS_get_class_by_name(pcx, name)) == NULL) {
        JS_ReportError(cx, "Can't find class '%s'", name);
        return JS_FALSE;
    }

    slot = JSVAL_TO_INT(id);

    if ((pprop = PJS_get_property_by_id(pcls,  (int8) slot)) == NULL) {
        JS_ReportError(cx, "Can't find property handler");
        return JS_FALSE;
    }

    if (pprop->getter == NULL) {
        JS_ReportError(cx, "Property is write-only");
        return JS_FALSE;
    }

    if (invocation_mode) {
        caller = (SV *) JS_GetPrivate(cx, obj);
    }
    else {
        caller = newSVpv(pcls->pkg, 0);
    }

    if (perl_call_sv_with_jsvals(cx, obj, pprop->getter,
                                 caller, 0, NULL, vp) < 0) {
        return JS_FALSE;
    }

    return JS_TRUE;
}

static JSBool PJS_invoke_perl_property_setter(JSContext *cx, JSObject *obj, jsval id, jsval *vp) {
    PJS_Context *pcx;
    PJS_Class *pcls;
    PJS_Property *pprop;
    SV *caller;
    char *name;
    jsint slot;
    U8 invocation_mode;

    if (!JSVAL_IS_INT(id)) {
        return JS_TRUE;
    }
    
    if((pcx = PJS_GET_CONTEXT(cx)) == NULL) {
        JS_ReportError(cx, "Can't find context %d", cx);
        return JS_FALSE;
    }

    if (JS_TypeOfValue(cx, OBJECT_TO_JSVAL(obj)) == JSTYPE_OBJECT) {
        /* Called as instsance */
        JSClass *clasp = PJS_GET_CLASS(cx, obj);
        name = (char *) clasp->name;
        invocation_mode = 1;
    }
    else {
        /* Called as static */
        JSFunction *parent_jfunc = JS_ValueToFunction(cx, OBJECT_TO_JSVAL(obj));
        if (parent_jfunc == NULL) {
            JS_ReportError(cx, "Failed to extract class for static property getter");
            return JS_FALSE;
        }
        name = (char *) JS_GetFunctionName(parent_jfunc);
        invocation_mode = 0;
    }
    
    if((pcls = PJS_get_class_by_name(pcx, name)) == NULL) {
        JS_ReportError(cx, "Can't find class '%s'", name);
        return JS_FALSE;
    }

    slot = JSVAL_TO_INT(id);

    if ((pprop = PJS_get_property_by_id(pcls,  (int8) slot)) == NULL) {
        JS_ReportError(cx, "Can't find property handler");
        return JS_FALSE;
    }

    if (pprop->setter == NULL) {
        JS_ReportError(cx, "Property is read-only");
        return JS_FALSE;
    }

    if (invocation_mode) {
        caller = (SV *) JS_GetPrivate(cx, obj);
    }
    else {
        caller = newSVpv(pcls->pkg, 0);
    }

    if (perl_call_sv_with_jsvals(cx, obj, pprop->setter,
                                 caller, 1, vp, NULL) < 0) {
        return JS_FALSE;
    }

    return JS_TRUE;
}

static JSFunctionSpec *PJS_add_class_functions(PJS_Class *pcls, HV *fs, U8 flags) {
    JSFunctionSpec *fs_list, *current_fs;
    PJS_Function *pfunc;
    HE *entry;
    char *name;
    I32 len;
    SV *callback;
    
    I32 number_of_keys = hv_iterinit(fs);

    Newz(1, fs_list, number_of_keys + 1, JSFunctionSpec);

    current_fs = fs_list;

    while((entry = hv_iternext(fs)) != NULL) {
        name = hv_iterkey(entry, &len);
        callback = hv_iterval(fs, entry);

        len = strlen(name);
        
        Newz(1, pfunc, 1, PJS_Function);
        if (pfunc == NULL) {
            /* We might need to free more memory stuff here */
            croak("Failed to allocate memory for PJS_Function");
        }

        /* Name of function */
        Newz(1, pfunc->name, len + 1, char);
        if (pfunc->name == NULL) {
            Safefree(pfunc);
            croak("Failed to allocate memory for PJS_Function name");
        }
        Copy(name, pfunc->name, len, char);

        /* Setup JSFunctionSpec */
        Newz(1, current_fs->name, len + 1, char);
        if (current_fs->name == NULL) {
            Safefree(pfunc->name);
            Safefree(pfunc);
            croak("Failed to allocate memory for JSFunctionSpec name");
        }
        Copy(name, current_fs->name, len, char);

        current_fs->call = PJS_invoke_perl_object_method;
        current_fs->nargs = 0;
        current_fs->flags = 0;
        current_fs->extra = 0;

        pfunc->callback = SvREFCNT_inc(callback);
        
        /* Add entry to linked list */
        pfunc->_next = pcls->methods;
        pcls->methods = pfunc;
        
        /* Get next function */
        current_fs++;
    }

    current_fs->name = 0;
    current_fs->call = 0;
    current_fs->nargs = 0;
    current_fs->flags = 0;
    current_fs->extra = 0;

    return fs_list;
}

static JSPropertySpec *PJS_add_class_properties(PJS_Class *pcls, HV *ps, U8 flags) {
    JSPropertySpec *ps_list, *current_ps;
    PJS_Property *pprop;
    HE *entry;
    char *name;
    I32 len;
    AV *callbacks;
    SV **getter, **setter;
    
    I32 number_of_keys = hv_iterinit(ps);

    Newz(1, ps_list, number_of_keys + 1, JSPropertySpec);

    current_ps = ps_list;

    while((entry = hv_iternext(ps)) != NULL) {
        name = hv_iterkey(entry, &len);
        callbacks = (AV *) SvRV(hv_iterval(ps, entry));

        len = strlen(name);
        
        Newz(1, pprop, 1, PJS_Property);
        if (pprop == NULL) {
            /* We might need to free more memory stuff here */
            croak("Failed to allocate memory for PJS_Property");
        }

        /* Setup JSFunctionSpec */
        Newz(1, current_ps->name, len + 1, char);
        if (current_ps->name == NULL) {
            Safefree(pprop);
            croak("Failed to allocate memory for JSPropertySpec name");
        }
        Copy(name, current_ps->name, len, char);
        
        getter = av_fetch(callbacks, 0, 0);
        setter = av_fetch(callbacks, 1, 0);

        pprop->getter = getter != NULL && SvTRUE(*getter) ? SvREFCNT_inc(*getter) : NULL;
        pprop->setter = setter != NULL && SvTRUE(*setter) ? SvREFCNT_inc(*setter) : NULL;

        current_ps->getter = PJS_invoke_perl_property_getter;
        current_ps->setter = PJS_invoke_perl_property_setter;
        current_ps->tinyid = pcls->next_property_id++;

        current_ps->flags = JSPROP_ENUMERATE;
        
        if (setter == NULL) {
            current_ps->flags |= JSPROP_READONLY;
        }

        pprop->tinyid = current_ps->tinyid;
        pprop->_next = pcls->properties;
        pcls->properties = pprop;

        current_ps++;
    }
    
    current_ps->name = 0;
    current_ps->tinyid = 0;
    current_ps->flags = 0;
    current_ps->getter = 0;
    current_ps->setter = 0;
        
    return ps_list;
}

static void PJS_bind_class(PJS_Context *pcx, char *name, char *pkg, SV *cons, HV *fs, HV *static_fs, HV *ps, HV *static_ps, U32 flags) {
    PJS_Class *pcls;

    if (pcx == NULL) {
        croak("Can't bind_class in an undefined context");
    }

    Newz(1, pcls, 1, PJS_Class);
    if (pcls == NULL) {
        croak("Failed to allocate memory for PJS_Class");
    }

    /* Add "package" */
    Newz(1, pcls->pkg, strlen(pkg) + 1, char);
    if (pcls->pkg == NULL) {
        PJS_free_class(pcls);
        croak("Failed to allocate memory for pkg");
    }
    Copy(pkg, pcls->pkg, strlen(pkg), char);

    /* Create JSClass "clasp" */
    Newz(1, pcls->clasp, 1, JSClass);
    Zero(pcls->clasp, 1, JSClass);
    
    if (pcls->clasp == NULL) {
        PJS_free_class(pcls);
        croak("Failed to allocate memory for JSClass");
    }

    Newz(1, pcls->clasp->name, strlen(name) + 1, char);
    if (pcls->clasp->name == NULL) {
        PJS_free_class(pcls);
        croak("Failed to allocate memory for name in JSClass");
    }
    Copy(name, pcls->clasp->name, strlen(name), char);

    pcls->methods = NULL;
    pcls->properties = NULL;
    
    pcls->clasp->flags = JSCLASS_HAS_PRIVATE;
    pcls->clasp->addProperty = JS_PropertyStub;
    pcls->clasp->delProperty = JS_PropertyStub;  
    pcls->clasp->getProperty = PJS_invoke_perl_property_getter;
    pcls->clasp->setProperty = PJS_invoke_perl_property_setter;
    pcls->clasp->enumerate = JS_EnumerateStub;
    pcls->clasp->resolve = JS_ResolveStub;
    pcls->clasp->convert = JS_ConvertStub;
    pcls->clasp->finalize = PJS_finalize;

    pcls->clasp->getObjectOps = NULL;
    pcls->clasp->checkAccess = NULL;
    pcls->clasp->call = NULL;
    pcls->clasp->construct = NULL;
    pcls->clasp->hasInstance = NULL;

    pcls->next_property_id = 0;
    
    /* Per-object functions and properties */
    pcls->fs = PJS_add_class_functions(pcls, fs, PJS_INSTANCE_METHOD);
    pcls->ps = PJS_add_class_properties(pcls, ps, PJS_INSTANCE_METHOD);
    
    /* Class functions and properties */
    pcls->static_fs = PJS_add_class_functions(pcls, static_fs, PJS_CLASS_METHOD);
    pcls->static_ps = PJS_add_class_properties(pcls, static_ps, PJS_CLASS_METHOD);

    /* Initialize class */
    pcls->proto = JS_InitClass(pcx->cx, JS_GetGlobalObject(pcx->cx),
                               NULL, pcls->clasp,
                               PJS_construct_perl_object, 0,
                               pcls->ps /* ps */, pcls->fs,
                               pcls->static_ps /* static_ps */, pcls->static_fs /* static_fs */);

    if (pcls->proto == NULL) {
        PJS_free_class(pcls);
        croak("Failed to initialize class in context");
    }

    /* refcount constructor */
    pcls->cons = SvREFCNT_inc(cons);
    
    /* Add class to list of classes in context */
    pcls->_next = pcx->classes;
    pcx->classes = pcls;
}

/*
  Free memory occupied by PJS_Context structure
*/
static void PJS_free_context(PJS_Context *pcx) {
    if (pcx == NULL) {
        return;
    }
    
    /* Check if we have any bound functions */
    PJS_Function *pfunc = pcx->functions, *pfunc_next;
    while (pfunc != NULL) {
        pfunc_next = pfunc->_next;
        PJS_free_function(pfunc);
        pfunc = pfunc_next;
    }

    /* Check if we have any bound classes */
    PJS_Class *pcls = pcx->classes, *pcls_next;
    while (pcls != NULL) {
        pcls_next = pcls->_next;
        PJS_free_class(pcls);
        pcls = pcls_next;
    }

    /* Destory context */
    JS_DestroyContext(pcx->cx);

    Safefree(pcx);
}

/*
  Free memory occupied by PJS_Function structure
*/
static void PJS_free_function(PJS_Function *pfunc) {
    if (pfunc == NULL) {
        return;
    }

    if (pfunc->callback != NULL) {
        SvREFCNT_dec(pfunc->callback);
    }
    
    if (pfunc->name != NULL) {
        Safefree(pfunc->name);
    }

    if (pfunc != NULL) {
        Safefree(pfunc);
    }
}

static void PJS_free_JSFunctionSpec(JSFunctionSpec *fs_list) {
    JSFunctionSpec *fs;
    
    if (fs_list == NULL) {
        return;
    }

    for (fs = fs_list; fs->name != NULL; fs++) {
        Safefree(fs->name);
    }

    Safefree(fs_list);
}

static void PJS_free_property(PJS_Property *pfunc) {
    if (pfunc == NULL) {
        return;
    }

    if (pfunc->getter != NULL) {
        SvREFCNT_dec(pfunc->getter);
    }

    if (pfunc->setter != NULL) {
        SvREFCNT_dec(pfunc->setter);
    }

    Safefree(pfunc);
}

static void PJS_free_JSPropertySpec(JSPropertySpec *ps_list) {
    JSPropertySpec *ps;
    
    if (ps_list == NULL) {
        return;
    }

    for(ps = ps_list; ps->name; ps++) {
        Safefree(ps->name);
    }

    Safefree(ps_list);
}

/*
  Free memory occupied by PJS_Class structure
*/
static void PJS_free_class(PJS_Class *pcls) {
    PJS_Function *method;
    PJS_Property *property;
    
    if (pcls == NULL) {
        return;
    }

    if (pcls->cons != NULL) {
        SvREFCNT_dec(pcls->cons);
    }

    if (pcls->pkg != NULL) {
        Safefree(pcls->pkg);
    }

    method = pcls->methods;
    while (method != NULL) {
        PJS_Function *next = method->_next;
        PJS_free_function(method);
        method = next;
    }
    PJS_free_JSFunctionSpec(pcls->fs);
    PJS_free_JSFunctionSpec(pcls->static_fs);
    
    property = pcls->properties;
    while (property != NULL) {
        PJS_Property *next = property->_next;
        PJS_free_property(property);
        property = next;
    }
    PJS_free_JSPropertySpec(pcls->ps);
    PJS_free_JSPropertySpec(pcls->static_ps);
    
    Safefree(pcls);
}

/* Perl Callback functions */
static void PJS_bind_function(PJS_Context *pcx, const char *name, SV *cv) {
    JSContext *jcx;
    PJS_Function *pfunc = NULL;
	
    if(pcx != NULL) {
        jcx = pcx->cx;		
        
        /* Allocate memory for a new callback */
        Newz(1, pfunc, 1, PJS_Function);
        if (pfunc == NULL) {
            croak("Failed to allocate memory for PJS_Function");
        }
        
        /* Allocate memory for the native name */
        Newz(1, pfunc->name, strlen(name) + 1, char);
        if (pfunc->name == NULL) {
            Safefree(pfunc);
            croak("Failed to allocate memory for function name");
        }
        Copy(name, pfunc->name, strlen(name), char);

        /* Add the function to the javascript context */
        if (JS_DefineFunction(jcx, JS_GetGlobalObject(jcx), name, PJS_invoke_perl_function, 0, 0) == JS_FALSE) {
            PJS_free_function(pfunc);
            croak("Failed to define function");
        }

        /* Make sure we increase the refcount so it's not freed by perl */
        pfunc->callback = SvREFCNT_inc(cv);

        /* Insert function in context linked list */
        pfunc->_next = pcx->functions;
        pcx->functions = pfunc;      
    }
    else {
        croak("Failed to find context");
    }
}

/* Converts perl values to equivalent JavaScript values */
static JSBool SVToJSVAL_real(JSContext *cx, JSObject *obj, SV *ref, jsval *rval, int nofunc) {
    if (sv_isobject(ref) && strcmp(HvNAME(SvSTASH(SvRV(ref))), PJS_BOXED_PACKAGE) == 0) {
        /* XXX: test this more */
        ref = *av_fetch((AV *) SvRV(SvRV(ref)), 0, 0);
    }
    
    if (sv_isobject(ref)) {
        PJS_Context *pcx;
        PJS_Class *pjsc;
        JSObject *newobj;
        HV *stash = SvSTASH(SvRV(ref));
        char *name = HvNAME(stash);

        if (strcmp(name, PJS_FUNCTION_PACKAGE) == 0) {
            JSFunction *func = INT2PTR(JSFunction *,
                                       SvIV((SV *) SvRV(PJS_call_perl_method("content", ref, NULL))));
            JSObject *obj = JS_GetFunctionObject(func);
            *rval = OBJECT_TO_JSVAL(obj);
            return JS_TRUE;
            
        }
        
        if((pcx = PJS_GET_CONTEXT(cx)) == NULL) {
            *rval = JSVAL_VOID;
            return JS_FALSE;
        }
        
        if((pjsc = PJS_get_class_by_package(pcx, name)) == NULL) {
            *rval = JSVAL_VOID;
            return JS_FALSE;
        }
        
        SvREFCNT_inc(ref);
        
        newobj = JS_NewObject(cx, pjsc->clasp, NULL, obj);
        
        JS_SetPrivate(cx, newobj, (void *) ref);
        
        *rval = OBJECT_TO_JSVAL(newobj);
        
        return JS_TRUE;
    }

    if (!SvOK(ref)) {
        /* Returned value is undefined */
        *rval = JSVAL_VOID;
    }
    else if (SvIOK(ref)) {
        /* Returned value is an integer */
        *rval = INT_TO_JSVAL(SvIV(ref));
    }
    else if (SvNOK(ref)) {
        JS_NewDoubleValue(cx, SvNV(ref), rval);
    }
    else if(SvPOK(ref)) {
        /* Returned value is a string */
        char *str;
        STRLEN len;

#ifdef JS_C_STRINGS_ARE_UTF8
        str = sv_2pvutf8(ref, &len);
#else
        str = SvPV(ref, len);
#endif
        *rval = STRING_TO_JSVAL(JS_NewStringCopyN(cx, str, len));
    }
    else if(SvROK(ref)) {
        I32	type;
        
        type = SvTYPE(SvRV(ref));

        /* Most likely it's an hash that is returned */
        if(type == SVt_PVHV) {
            HV *hv = (HV *) SvRV(ref);
            JSObject *new_obj;
            JSClass *jsclass;
            
            new_obj = JS_NewObject(cx, NULL, NULL, NULL);
            
            if(new_obj == NULL) {
                croak("Failed to create new JavaScript object");
            }
            
            /* Assign properties, lets iterate over the hash */
            I32 items;
            HE *key;
            char *keyname;
            I32 keylen;
            SV *keyval;
            jsval elem;
                
            items = hv_iterinit(hv);
                
            while((key = hv_iternext(hv)) != NULL) {
                keyname = hv_iterkey(key, &keylen);
                keyval = (SV *) hv_iterval(hv, key);
                
                if (SVToJSVAL(cx, obj, keyval, &elem) == JS_FALSE) {
                    *rval = JSVAL_VOID;
                    return JS_FALSE;
                }
                
                if (JS_DefineProperty(cx, new_obj, keyname, elem, NULL, NULL, JSPROP_ENUMERATE) == JS_FALSE) {
                    warn("Failed to defined property %%", keyname);
                }
            }
                
            *rval = OBJECT_TO_JSVAL(new_obj);
        } else if(type == SVt_PVAV) {
            /* Then it's probablly an array */
            AV *av = (AV *) SvRV(ref);
            jsint av_length;
            int cnt;
            jsval *elems;
            JSObject *arr_obj;

            av_length = av_len(av);

            Newz(1, elems, av_length + 1, jsval);
            if (elems == NULL) {
                croak("Failed to allocate memory for array of jsval");
            }
            
            for(cnt = av_length + 1; cnt > 0; cnt--) {
                if (SVToJSVAL(cx, obj, av_pop(av), &(elems[cnt - 1])) == JS_FALSE) {
                    *rval = JSVAL_VOID;
                    return JS_FALSE;
                }
            }
            
            arr_obj = JS_NewArrayObject(cx, av_length + 1, elems);
            
            *rval = OBJECT_TO_JSVAL(arr_obj);
        }
        else if(type == SVt_PVGV) {
            *rval = PRIVATE_TO_JSVAL(ref);
        }
        else if(type == SVt_PV || type == SVt_IV || type == SVt_NV || type == SVt_RV) {
            /* Not very likely to return a reference to a primitive type, but we need to support that aswell */
            warn("returning references to primitive types is not supported yet");	
        }
        else if(type == SVt_PVCV) {
            if (nofunc) {
                return JS_TRUE;
            }

            JSObject *newobj;
            JSFunction *jsfun;
            SvREFCNT_inc(ref);

            jsfun = JS_NewFunction(cx, perl_call_jsfunc, 0, 0, NULL, NULL);
            newobj = JS_GetFunctionObject(jsfun);
            /* put the cv as a property on the function object */
            if (JS_DefineProperty(cx, newobj, "_perl_func", PRIVATE_TO_JSVAL(ref), NULL, NULL, 0) == JS_FALSE) {
                warn("Failed to defined property for _perl_func");
            }
            *rval = OBJECT_TO_JSVAL(newobj);
        }
        else {
            warn("JavaScript.pm not handling this yet");
            *rval = JSVAL_VOID;
            return JS_FALSE;
        }
    }
    else {
        warn("I have no idea what ref is (it's of type %i), I'll pretend it's null", SvTYPE(ref));
        *rval = JSVAL_VOID;
    }
    
    return JS_TRUE;
}

/* Converts a JavaScript value to equivalent Perl value */
static JSBool JSVALToSV(JSContext *cx, HV *seen, jsval v, SV** sv) {
    if (JSVAL_IS_PRIMITIVE(v)) {
        if (JSVAL_IS_NULL(v) || JSVAL_IS_VOID(v)){
            *sv = &PL_sv_undef;
        }
        else if (JSVAL_IS_INT(v)) {
            sv_setiv(*sv, JSVAL_TO_INT(v));
        }
        else if (JSVAL_IS_DOUBLE(v)) {
            sv_setnv(*sv, *JSVAL_TO_DOUBLE(v));
        }
        else if (JSVAL_IS_STRING(v)) {
            /* XXX: review this, JS_GetStringBytes twice causing assertaion failure */
            /* TODO: Migrate from fotango */
#ifdef JS_C_STRINGS_ARE_UTF8
            char *tmp = JS_smprintf("%hs", JS_GetStringChars(JSVAL_TO_STRING(v)));
            sv_setpv(*sv, tmp);
            SvUTF8_on(*sv);
#else
            sv_setpv(*sv, JS_GetStringBytes(JSVAL_TO_STRING(v)));
#endif         
        }
        else if (JSVAL_IS_BOOLEAN(v)) {
            if (JSVAL_TO_BOOLEAN(v)) {
                *sv = &PL_sv_yes;
            }
            else {
	        *sv = &PL_sv_no;
            }
        }
        else {
            croak("Unknown primitive type");
        }
    }
    else {
        if (JSVAL_IS_OBJECT(v)) {
            JSObject *object = JSVAL_TO_OBJECT(v);
            
            /* stringify object with a default value for now, such as
               String.  We might want to actually tie the object in the
               future, so the additional properties won't go away */
            {
                jsval dvalue;
                if (OBJ_DEFAULT_VALUE(cx, object, JSTYPE_OBJECT, &dvalue) &&
                    JSVAL_IS_STRING(dvalue)) {
                    sv_setpv(*sv, JS_GetStringBytes(JSVAL_TO_STRING(dvalue)));
                    return JS_TRUE;
                }
            }
            
            if (JS_ObjectIsFunction(cx, object)) {
                JSFunction *jsfun = JS_ValueToFunction(cx, v);
                SV *pcx = sv_2mortal(newSViv(PTR2IV(PJS_GET_CONTEXT(cx))));
                SV *content = sv_2mortal(newRV_noinc(newSViv(PTR2IV(jsfun))));
                jsval *x;
                
                Newz(1, x, 1, jsval);
                if (x == NULL) {
                    croak("Failed to allocate memory for jsval");
                }
                *x = v;
                JS_AddRoot(cx, (void *)x);

                sv_setsv(*sv, PJS_call_perl_method("new",
                                                   newSVpv(PJS_FUNCTION_PACKAGE, 0),
                                                   content, pcx,
                                                   sv_2mortal(newSViv(PTR2IV(x))), NULL));
                return JS_TRUE;
            }
            else if (OBJ_IS_NATIVE(object) &&
                     (OBJ_GET_CLASS(cx, object)->flags & JSCLASS_HAS_PRIVATE) &&
                     (strcmp(OBJ_GET_CLASS(cx, object)->name, "Error") != 0)) {

                /* Object with a private means the actual perl object is there */
                /* This is kludgy because function is also object with private,
                   we need to turn this to use hidden property on object */
                SV *priv = (SV *)JS_GetPrivate(cx, object);
                if (priv && SvROK(priv)) {
                    SvREFCNT_inc(priv);
                    sv_setsv(*sv, priv);
                    return JS_TRUE;
                }
            }
            
            int destroy_hv = 0;
            if (!seen) {
                seen = newHV();
                destroy_hv = 1;
            }
            
            SV **used;
            char hkey[32];
            int klen = snprintf(hkey, 32, "%p", object);
            if (used = hv_fetch(seen, hkey, klen, 0)) {
                sv_setsv(*sv, *used);
                return JS_TRUE;
            } else if(JS_IsArrayObject(cx, object)) {
                SV *arr_sv;
                
                arr_sv = JSARRToSV(cx, seen, object);
                
                sv_setsv(*sv, arr_sv);
            } else {
                SV *hash_sv;
                
                hash_sv = JSHASHToSV(cx, seen, object);
                sv_setsv(*sv, hash_sv);
            }
            
            if (destroy_hv) {
                hv_undef(seen);
            }
        }
        else {
            croak("Not an object nor a primitive");
        }
    }
    
    
    return JS_TRUE;
}

/* Converts an JavaScript array object to an Perl array reference */
static SV *JSARRToSV(JSContext *cx, HV *seen, JSObject *object) {
    jsuint jsarrlen;
    jsuint index;
    jsval elem;
    
    AV *av = newAV();
    SV *sv = sv_2mortal(newRV_noinc((SV *) av));

    char hkey[32];
    int klen = snprintf(hkey, 32, "%p", object);

    hv_store(seen, hkey, klen, sv, 0);
    SvREFCNT_inc(sv);

    JS_GetArrayLength(cx, object, &jsarrlen);
    for(index = 0; index < jsarrlen; index++) {
        JS_GetElement(cx, object, index, &elem);
        
        SV *elem_sv;
        elem_sv = newSV(0);
        JSVALToSV(cx, seen, elem, &elem_sv);
        av_push(av, elem_sv);
    }

    return sv;
}

/* Converts a JavaScript object (not array) to a anonymous perl hash reference */
static SV *JSHASHToSV(JSContext *cx, HV *seen, JSObject *object) {
    JSIdArray *prop_arr = JS_Enumerate(cx, object);
    int idx;

    HV *hv = newHV();
    SV *sv = sv_2mortal(newRV_noinc((SV *) hv));
    
    char hkey[32];
    int klen = snprintf(hkey, 32, "%p", object);
    hv_store(seen, hkey, klen, sv, 0);
    SvREFCNT_inc(sv);
    
    for(idx = 0; idx < prop_arr->length; idx++) {
        jsval key;
        
        JS_IdToValue(cx, (prop_arr->vector)[idx], &key);
        
        if(JSVAL_IS_STRING(key)) {
            jsval value;
            char *js_key = JS_GetStringBytes(JSVAL_TO_STRING(key));
            
            if ( JS_GetProperty(cx, object, js_key, &value) == JS_FALSE ) {
                /* we're enumerating the properties of an object. This returns
                   false if there's no such property. Urk. */
                croak("this can't happen.");
            }
            
            SV *val_sv;
            val_sv = newSV(0);
            JSVALToSV(cx, seen, value, &val_sv);
            hv_store(hv, js_key, strlen(js_key), val_sv, 0);
        }
        else {
            croak("can't coerce object key into a hash");
        }
    }
 
    JS_DestroyIdArray(cx, prop_arr);
  
    return sv;
}

MODULE = JavaScript		PACKAGE = JavaScript
PROTOTYPES: DISABLE

char *
js_get_engine_version()
    CODE:
        RETVAL = (char *) JS_GetImplementationVersion();
    OUTPUT:
        RETVAL

SV*
js_does_handle_utf8()
    CODE:
#ifdef JS_C_STRINGS_ARE_UTF8
        RETVAL = &PL_sv_yes;
#else
        RETVAL = &PL_sv_no;
#endif
    OUTPUT:
        RETVAL
       
MODULE = JavaScript		PACKAGE = JavaScript::Runtime

PJS_Runtime *
jsr_create(maxbytes)
    int maxbytes
    PREINIT:
        PJS_Runtime *rt;
    CODE:
        Newz(1, rt, 1, PJS_Runtime);
        if(rt == NULL) {
            croak("Failed to allocate memoery for PJS_Runtime");
            XSRETURN_UNDEF;
        }

        rt->rt = JS_NewRuntime(maxbytes);
        if(rt->rt == NULL) {
            croak("Failed to create runtime");
            XSRETURN_UNDEF;
        }

        RETVAL = rt;
    OUTPUT:
        RETVAL

void
jsr_destroy(rt)
    PJS_Runtime *rt
    CODE:
        if (rt != NULL) {
            if (rt->interrupt_handler) {
                SvREFCNT_dec(rt->interrupt_handler);
            }
            
            JS_DestroyRuntime(rt->rt);
            Safefree(rt);
        }

void
jsr_set_interrupt_handler(rt,handler)
    PJS_Runtime *rt;
    SV *handler;
    PREINIT:
        JSTrapHandler trap_handler;
        void *ptr;
    CODE:
        if (!SvOK(handler)) {
            /* Remove handler */
            if (rt->interrupt_handler != NULL) {
                SvREFCNT_dec(rt->interrupt_handler);
            }

            rt->interrupt_handler = NULL;
            JS_ClearInterrupt(rt->rt, &trap_handler, &ptr);
        }
        else if (SvROK(handler) && SvTYPE(SvRV(handler)) == SVt_PVCV) {
            if (rt->interrupt_handler != NULL) {
                SvREFCNT_dec(rt->interrupt_handler);
            }
            
            rt->interrupt_handler = SvREFCNT_inc(handler);
            JS_SetInterrupt(rt->rt, PJS_interrupt_handler, rt);
        }

MODULE = JavaScript		PACKAGE = JavaScript::Context

PJS_Context *
jsc_create(rt, stacksize)
    PJS_Runtime	*rt;
    int		stacksize;
    PREINIT:
        PJS_Context *cx;
        JSObject *obj;
    CODE:
        Newz(1, cx, 1, PJS_Context);

        cx->cx = JS_NewContext(rt->rt, stacksize);

        if(cx->cx == NULL) {
            Safefree(cx);
            croak("Failed to create context");
            XSRETURN_UNDEF;
        }
#ifdef JSOPTION_DONT_REPORT_UNCAUGHT
        JS_SetOptions(cx->cx, JSOPTION_DONT_REPORT_UNCAUGHT);
#endif
        obj = JS_NewObject(cx->cx, &global_class, NULL, NULL);
        if (JS_InitStandardClasses(cx->cx, obj) == JS_FALSE) {
            warn("Standard classes not loaded properly.");
        }

        /* Add context to context list */
        cx->functions = NULL;
        cx->classes = NULL;
        cx->rt = rt;
        cx->next = rt->list;
        rt->list = cx;

        JS_SetContextPrivate(cx->cx, (void *)cx);

        RETVAL = cx;
    OUTPUT:
	RETVAL

int
jsc_destroy(cx)
    PJS_Context *cx;

    CODE:
        /* TODO - there must be more cleanup needed here */
        PJS_free_context(cx);
        RETVAL = 0;
    OUTPUT:
        RETVAL

void
jsc_set_error_handler(cx, handler)
    PJS_Context *cx;
    SV *handler;
    CODE:
        if (!SvOK(handler)) {
            /* Remove handler */
            if (cx->error_handler != NULL) {
                SvREFCNT_dec(cx->error_handler);
            }

            cx->error_handler = NULL;
            JS_SetErrorReporter(cx->cx, NULL);
        }
        else if (SvROK(handler) && SvTYPE(SvRV(handler)) == SVt_PVCV) {
            if (cx->error_handler != NULL) {
                SvREFCNT_dec(cx->error_handler);
            }
            cx->error_handler = SvREFCNT_inc(handler);
            JS_SetErrorReporter(cx->cx, PJS_error_handler);
        }

void
jsc_set_branch_handler(cx, handler)
    PJS_Context *cx;
    SV *handler;
    CODE:
        if (!SvOK(handler)) {
            /* Remove handler */
            if (cx->branch_handler != NULL) {
                SvREFCNT_dec(cx->branch_handler);
            }

            cx->branch_handler = NULL;
            JS_SetBranchCallback(cx->cx, NULL);
        }
        else if (SvROK(handler) && SvTYPE(SvRV(handler)) == SVt_PVCV) {
            if (cx->branch_handler != NULL) {
                SvREFCNT_dec(cx->branch_handler);
            }

            cx->branch_handler = SvREFCNT_inc(handler);
            JS_SetBranchCallback(cx->cx, PJS_branch_handler);
        }

void
jsc_bind_function(cx, name, callback)
    PJS_Context	*cx;
    char *name;
    SV *callback;
    CODE:
        PJS_bind_function(cx, name, callback);

int
jsc_bind_class(cx, name, pkg, cons, fs, static_fs, ps, static_ps, flags)
    PJS_Context	*cx;
    char *name;
    char *pkg;
    SV *cons;
    HV *fs;
    HV *static_fs;
    HV *ps;
    HV *static_ps;
    U32 flags;
    CODE:
        PJS_bind_class(cx, name, pkg, cons, fs, static_fs, ps, static_ps, flags);

int
jsc_bind_value(cx, parent, name, object)
    PJS_Context     *cx;
    char            *parent;
    char            *name;
    SV              *object;
    PREINIT:
        jsval val, pval;
        JSObject *gobj, *pobj;
    CODE:
        gobj = JS_GetGlobalObject(cx->cx);

        if (strlen(parent)) {
            JS_EvaluateScript(cx->cx, gobj, parent, strlen(parent), "", 1, &pval);
            pobj = JSVAL_TO_OBJECT(pval);
        }
        else {
            pobj = JS_GetGlobalObject(cx->cx);
        }

        if (SVToJSVAL(cx->cx, pobj, object, &val) == JS_FALSE) {
            fprintf(stderr, "not working\n");
            val = JSVAL_VOID;
            XSRETURN_UNDEF;
        }
        if (JS_SetProperty(cx->cx, pobj, name, &val) == JS_FALSE) {
            fprintf(stderr, "can't set prop\n");
            XSRETURN_UNDEF;
        }
        RETVAL = val;
    OUTPUT:
        RETVAL

jsval 
jsc_eval(cx, source, name)
    PJS_Context	*cx;
    char *source;
    char *name;
    PREINIT:
        jsval rval;
        JSContext *jcx;
        JSObject *gobj, *eobj;
        JSScript *script;
        JSBool ok;
    CODE:
        sv_setsv(ERRSV, &PL_sv_undef);

        jcx = cx->cx;
        gobj = JS_GetGlobalObject(jcx);
#ifndef JSOPTION_DONT_REPORT_UNCAUGHT
        script = JS_CompileScript(jcx, gobj, source, strlen(source), name, 1);
        if (script == NULL) {
            PJS_report_exception(cx);
            XSRETURN_UNDEF;
        }
        ok = js_Execute(jcx, gobj, script, NULL, 0, &rval);

        if (ok == JS_FALSE) {
            PJS_report_exception(cx);
        }
        JS_DestroyScript(jcx, script);
#else
        ok = JS_EvaluateScript(jcx, gobj, source, strlen(source), name, 1, &rval);
        if (ok == JS_FALSE) {
            PJS_report_exception(cx);
        }
#endif
        if (ok == JS_FALSE) {
            /* We must check ERRSV here because our interrupt_handler
               might have thrown the exception causing abort */
            XSRETURN_UNDEF;
        }
 
        RETVAL = rval;
    OUTPUT:
        RETVAL

void
jsc_free_root(cx, root)
    PJS_Context *cx;
    SV *root;
    CODE:
         jsval *x = INT2PTR(jsval *, SvIV(root));
         JS_RemoveRoot(cx->cx, x);

jsval
jsc_call(cx, function, args)
    PJS_Context	*cx;
    SV *function;
    SV *args;
    PREINIT:
        jsval rval;
        jsval fval;
        char *name;
        STRLEN len;
        IV tmp;
        JSFunction *func;
    CODE:
        if (sv_isobject(function) && sv_derived_from(function, PJS_FUNCTION_PACKAGE)) {
            tmp = SvIV((SV*)SvRV(PJS_call_perl_method("content", function, NULL)));
            func = INT2PTR(JSFunction *, tmp);

            if (PJS_call_javascript_function(cx, (jsval) (func->object), args, &rval) == JS_FALSE) {
                /* Exception was thrown */
                XSRETURN_UNDEF;
            }
        }
        else {
            name = SvPV(function, len);

            if (JS_GetProperty(cx->cx, JS_GetGlobalObject(cx->cx), name, &fval) == JS_FALSE) {
                croak("No function named '%s' exists", name);
            }
            
            if(JSVAL_IS_VOID(fval) || JSVAL_IS_NULL(fval)) {
                croak("Undefined subroutine %s called", name);
            }
            else if (JS_ValueToFunction(cx->cx, fval) != NULL) {
                if (PJS_call_javascript_function(cx, fval, args, &rval) == JS_FALSE) {
                    /* Exception was thrown */
                    XSRETURN_UNDEF;
                }
            }
            else {
                croak("Undefined subroutine %s called", name);
            }
        }

        RETVAL = rval;
    OUTPUT:
        RETVAL

SV *
jsc_call_in_context( cx, afunc, args, rcx, class )
    PJS_Context *cx;
    SV *afunc
    SV *args;
    SV *rcx;
    char *class;
    PREINIT:
        jsval rval;
        jsval aval;
        JSFunction *func;
        int av_length;
        jsval *arg_list;
        jsval context;
        jsval jsproto;
        int cnt;
        AV *av;
        SV *val, *value;
        IV tmp;
    CODE:
        tmp = SvIV((SV *) SvRV(PJS_call_perl_method("content", afunc, NULL)));
        func = INT2PTR(JSFunction *,tmp);
        av = (AV *) SvRV(args);
        av_length = av_len(av);
        Newz(1, arg_list, av_length + 1, jsval);
        for(cnt = av_length + 1; cnt > 0; cnt--) {
            val = *av_fetch(av, cnt-1, 0);
            if (SVToJSVAL(cx->cx, JS_GetGlobalObject(cx->cx), val, &(arg_list[cnt - 1])) == JS_FALSE) {
                croak("cannot convert argument %i to JSVALs", cnt);
            }
        }
        if (SVToJSVAL(cx->cx, JS_GetGlobalObject(cx->cx), rcx, &context) == JS_FALSE) {
            croak("cannot convert JS context to JSVAL");
        }
        JSObject *jsobj = JSVAL_TO_OBJECT(context);

        if (strlen(class) > 0) {
            if( JS_GetProperty(cx->cx, JS_GetGlobalObject(cx->cx), class, &aval) == JS_FALSE ) {
                croak("cannot get property %s",class);
                Safefree(arg_list);
                XSRETURN_UNDEF;
            }
            JS_SetPrototype(cx->cx, jsobj, JSVAL_TO_OBJECT(aval));
        }
        if (!JS_CallFunction(cx->cx, jsobj, func, av_length+1, arg_list, &rval)) {
            fprintf(stderr, "error in call\n");
            Safefree(arg_list);
            XSRETURN_UNDEF;
        }
        value = newSViv(0);
        JSVALToSV(cx->cx, NULL, rval, &value);
        RETVAL = value;
        Safefree(arg_list);
    OUTPUT:
        RETVAL

int
jsc_can(cx, func_name)
    PJS_Context	*cx;
    char *func_name;
    PREINIT:
        jsval val;
        JSObject *object;
    CODE:
        RETVAL = 0;

        if (JS_GetProperty(cx->cx, JS_GetGlobalObject(cx->cx), func_name, &val)) {
            if (JSVAL_IS_OBJECT(val)) {
                JS_ValueToObject(cx->cx, val, &object);
                if (strcmp(OBJ_GET_CLASS(cx->cx, object)->name, "Function") == 0 &&
                    JS_ValueToFunction(cx->cx, val) != NULL) {
                    RETVAL = 1;
                }
            }
        }
    OUTPUT:
        RETVAL


MODULE = JavaScript		PACKAGE = JavaScript::Script

jsval
jss_execute(psc)
    PJS_Script *psc;
    PREINIT:
        PJS_Context *cx;
        jsval rval;
    CODE:
        cx = psc->cx;
        if(!JS_ExecuteScript(cx->cx, JS_GetGlobalObject(cx->cx), psc->script, &rval)) {
            XSRETURN_UNDEF;
        }
        RETVAL = rval;
    OUTPUT:
        RETVAL

PJS_Script *
jss_compile(cx, source)
    PJS_Context	*cx;
    char *source;
    PREINIT:
        PJS_Script *psc;
        JSScript *script;
        uintN line = 0; /* May be uninitialized by some compilers */
    CODE:
        Newz(1, psc, 1, PJS_Script);
        if(psc == NULL) {
            croak("Failed to allocate memory for PJS_Script");
        }

        psc->cx = cx;
        psc->script = JS_CompileScript(cx->cx, JS_GetGlobalObject(cx->cx), source, strlen(source), "Perl", line);

        if(psc->script == NULL) {
            Safefree(psc);
            XSRETURN_UNDEF;
        }

        RETVAL = psc;
    OUTPUT:
	RETVAL
