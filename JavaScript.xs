#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "JavaScript.h"

MODULE = JavaScript     PACKAGE = JavaScript
PROTOTYPES: DISABLE

char *
js_get_engine_version()
    CODE:
        RETVAL = (char *) JS_GetImplementationVersion();
    OUTPUT:
        RETVAL

SV*
js_does_support_utf8()
    CODE:
#ifdef JS_C_STRINGS_ARE_UTF8
        RETVAL = &PL_sv_yes;
#else
        RETVAL = &PL_sv_no;
#endif
    OUTPUT:
        RETVAL

SV*
js_does_support_e4x()
    CODE:
#ifdef JS_ENABLE_E4X
        RETVAL = &PL_sv_yes;
#else
        RETVAL = &PL_sv_no;
#endif
    OUTPUT:
        RETVAL

SV*
js_does_support_threading()
    CODE:
#ifdef JS_THREADING
        RETVAL = &PL_sv_yes;
#else
        RETVAL = &PL_sv_no;
#endif
    OUTPUT:
        RETVAL

MODULE = JavaScript     PACKAGE = JavaScript::Runtime

PJS_Runtime *
jsr_create(maxbytes)
    int maxbytes
    PREINIT:
        PJS_Runtime *rt;
    CODE:
        rt = PJS_CreateRuntime(maxbytes);
        RETVAL = rt;
    OUTPUT:
        RETVAL

void
jsr_destroy(rt)
    PJS_Runtime *rt
    CODE:
        PJS_DestroyRuntime(rt);
        
void
jsr_add_interrupt_handler(rt,handler)
    PJS_Runtime *rt;
    PJS_TrapHandler *handler;
    CODE:
        PJS_AddTrapHandler(rt, handler);

void
jsr_remove_interrupt_handler(rt,handler)
    PJS_Runtime *rt;
    PJS_TrapHandler *handler;
    CODE:
        PJS_RemoveTrapHandler(rt, handler);
    
PJS_TrapHandler *
jsr_init_perl_interrupt_handler(cb)
    SV *cb;
    PREINIT:
        PJS_TrapHandler *handler;
    CODE:
        Newz(1, handler, 1, PJS_TrapHandler);
        handler->handler = PJS_perl_trap_handler;
        handler->data = (SV *) SvREFCNT_inc(cb);
        RETVAL = handler;
    OUTPUT:
        RETVAL
        
void
jsr_destroy_perl_interrupt_handler(handler)
    PJS_TrapHandler *handler;
    CODE:
        SvREFCNT_dec(handler->data);
        Safefree(handler);
    
MODULE = JavaScript     PACKAGE = JavaScript::Context

PJS_Context *
jsc_create(rt)
    PJS_Runtime *rt;
    CODE:
        RETVAL = PJS_CreateContext(rt);
    OUTPUT:
        RETVAL

int
jsc_destroy(cx)
    PJS_Context *cx;
    CODE:
        PJS_DestroyContext(cx);
        RETVAL = 0;
    OUTPUT:
        RETVAL

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
            JS_SetBranchCallback(PJS_GetJSContext(cx), NULL);
        }
        else if (SvROK(handler) && SvTYPE(SvRV(handler)) == SVt_PVCV) {
            if (cx->branch_handler != NULL) {
                SvREFCNT_dec(cx->branch_handler);
            }

            cx->branch_handler = SvREFCNT_inc(handler);
            JS_SetBranchCallback(PJS_GetJSContext(cx), PJS_branch_handler);
        }

void
jsc_bind_function(cx, name, callback)
    PJS_Context *cx;
    char *name;
    SV *callback;
    CODE:
        PJS_DefineFunction(cx, name, callback);

void
jsc_bind_class(cx, name, pkg, cons, fs, static_fs, ps, static_ps, flags)
    PJS_Context *cx;
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
        gobj = JS_GetGlobalObject(PJS_GetJSContext(cx));

        if (strlen(parent)) {
            JS_EvaluateScript(PJS_GetJSContext(cx), gobj, parent, strlen(parent), "", 1, &pval);
            pobj = JSVAL_TO_OBJECT(pval);
        }
        else {
            pobj = JS_GetGlobalObject(PJS_GetJSContext(cx));
        }

        if (PJS_ConvertPerlToJSType(PJS_GetJSContext(cx), NULL, pobj, object, &val) == JS_FALSE) {
            val = JSVAL_VOID;
            XSRETURN_UNDEF;
        }
        if (JS_SetProperty(PJS_GetJSContext(cx), pobj, name, &val) == JS_FALSE) {
            XSRETURN_UNDEF;
        }
        RETVAL = val;
    OUTPUT:
        RETVAL

jsval 
jsc_eval(cx, source, name)
    PJS_Context *cx;
    char *source;
    char *name;
    PREINIT:
        jsval rval;
        JSContext *jcx;
        JSObject *gobj;
        JSScript *script;
        JSBool ok;
    CODE:
        sv_setsv(ERRSV, &PL_sv_undef);

        jcx = PJS_GetJSContext(cx);
        gobj = JS_GetGlobalObject(jcx);
#ifndef JSOPTION_DONT_REPORT_UNCAUGHT
        script = JS_CompileScript(jcx, gobj, source, strlen(source), name, 1);
        if (script == NULL) {
            PJS_report_exception(cx);
            XSRETURN_UNDEF;
        }
        ok = JS_ExecuteScript(jcx, gobj, script, &rval);

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
            /* We must check ERRSV here because our trap_handler
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
    PREINIT:
         jsval *x;
    CODE:
         x = INT2PTR(jsval *, SvIV(root));
         JS_RemoveRoot(PJS_GetJSContext(cx), x);

jsval
jsc_call(cx, function, args)
    PJS_Context *cx;
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

            if (JS_GetProperty(PJS_GetJSContext(cx), JS_GetGlobalObject(PJS_GetJSContext(cx)), name, &fval) == JS_FALSE) {
                croak("No function named '%s' exists", name);
            }
            
            if(JSVAL_IS_VOID(fval) || JSVAL_IS_NULL(fval)) {
                croak("Undefined subroutine %s called", name);
            }
            else if (JS_ValueToFunction(PJS_GetJSContext(cx), fval) != NULL) {
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
        int cnt;
        AV *av;
        SV *val, *value;
        IV tmp;
        JSObject *jsobj;
    CODE:
        tmp = SvIV((SV *) SvRV(PJS_call_perl_method("content", afunc, NULL)));
        func = INT2PTR(JSFunction *,tmp);
        av = (AV *) SvRV(args);
        av_length = av_len(av);
        Newz(1, arg_list, av_length + 1, jsval);
        for(cnt = av_length + 1; cnt > 0; cnt--) {
            val = *av_fetch(av, cnt-1, 0);
            if (PJS_ConvertPerlToJSType(PJS_GetJSContext(cx), NULL, JS_GetGlobalObject(PJS_GetJSContext(cx)), val, &(arg_list[cnt - 1])) == JS_FALSE) {
                croak("cannot convert argument %i to JSVALs", cnt);
            }
        }
        if (PJS_ConvertPerlToJSType(PJS_GetJSContext(cx), NULL, JS_GetGlobalObject(PJS_GetJSContext(cx)), rcx, &context) == JS_FALSE) {
            croak("cannot convert JS context to JSVAL");
        }
        jsobj = JSVAL_TO_OBJECT(context);

        if (strlen(class) > 0) {
            if( JS_GetProperty(PJS_GetJSContext(cx), JS_GetGlobalObject(PJS_GetJSContext(cx)), class, &aval) == JS_FALSE ) {
                croak("cannot get property %s",class);
                Safefree(arg_list);
                XSRETURN_UNDEF;
            }
            JS_SetPrototype(PJS_GetJSContext(cx), jsobj, JSVAL_TO_OBJECT(aval));
        }
        if (!JS_CallFunction(PJS_GetJSContext(cx), jsobj, func, av_length+1, arg_list, &rval)) {
            fprintf(stderr, "error in call\n");
            Safefree(arg_list);
            XSRETURN_UNDEF;
        }
        value = newSViv(0);
        JSVALToSV(PJS_GetJSContext(cx), NULL, rval, &value);
        RETVAL = value;
        Safefree(arg_list);
    OUTPUT:
        RETVAL

int
jsc_can(cx, func_name)
    PJS_Context *cx;
    char *func_name;
    PREINIT:
        jsval val;
        JSObject *object;
    CODE:
        RETVAL = 0;

        if (JS_GetProperty(PJS_GetJSContext(cx), JS_GetGlobalObject(PJS_GetJSContext(cx)), func_name, &val)) {
            if (JSVAL_IS_OBJECT(val)) {
                JS_ValueToObject(PJS_GetJSContext(cx), val, &object);
                if (strcmp(OBJ_GET_CLASS(PJS_GetJSContext(cx), object)->name, "Function") == 0 &&
                    JS_ValueToFunction(PJS_GetJSContext(cx), val) != NULL) {
                    RETVAL = 1;
                }
            }
        }
    OUTPUT:
        RETVAL


MODULE = JavaScript     PACKAGE = JavaScript::Script

jsval
jss_execute(psc)
    PJS_Script *psc;
    PREINIT:
        PJS_Context *cx;
        jsval rval;
    CODE:
        cx = psc->cx;
        if(!JS_ExecuteScript(PJS_GetJSContext(cx), JS_GetGlobalObject(PJS_GetJSContext(cx)), psc->script, &rval)) {
            XSRETURN_UNDEF;
        }
        RETVAL = rval;
    OUTPUT:
        RETVAL

PJS_Script *
jss_compile(cx, source)
    PJS_Context *cx;
    char *source;
    PREINIT:
        PJS_Script *psc;
        uintN line = 0; /* May be uninitialized by some compilers */
    CODE:
        Newz(1, psc, 1, PJS_Script);
        if(psc == NULL) {
            croak("Failed to allocate memory for PJS_Script");
        }

        psc->cx = cx;
        psc->script = JS_CompileScript(PJS_GetJSContext(cx), JS_GetGlobalObject(PJS_GetJSContext(cx)), source, strlen(source), "Perl", line);

        if(psc->script == NULL) {
            Safefree(psc);
            XSRETURN_UNDEF;
        }

        RETVAL = psc;
    OUTPUT:
        RETVAL
