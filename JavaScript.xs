#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include <jsapi.h>
#include <malloc.h>

#define _IS_UNDEF(a) (SvANY(a) == SvANY(&PL_sv_undef))

/* Defines */

#define JS_PROP_PRIVATE 0x1
#define JS_PROP_READONLY 0x2
#define JS_CLASS_NO_INSTANCE 0x1

/* Global class, does nothing */
static
JSClass global_class = {
    "Global", 0,
    JS_PropertyStub,  JS_PropertyStub,  JS_PropertyStub,  JS_PropertyStub,
    JS_EnumerateStub, JS_ResolveStub,   JS_ConvertStub,   JS_FinalizeStub
};

/* Structures needed for callbacks */
/* If next is NULL, then the instance is the last in order */
struct PCB_Function {
	char			*js_native_name;		/* The name of the JavaScript function which this perl function is bound to */
	SV			*pl_func_reference;		/* The perl reference to the function */
	struct PCB_Function	*next;				/* Next function in list */
};

typedef struct PCB_Function PCB_Function;

struct PCB_Method {
	char			*js_native_name;
	SV			*pl_func_reference;
	struct PCB_Method	*next;
};

typedef struct PCB_Method PCB_Method;

struct PCB_Property {
	char			*name;
	I32			flags;
	struct PCB_Property	*next;
};

typedef struct PCB_Property PCB_Property;

struct PCB_Class {
	char			*classname;
	SV			*constructor;
	JSClass			*jsclass;
	JSObject		*base_obj;
	char			*package;
	PCB_Method		*methods;
	struct PCB_Class	*next;
	PCB_Property		*properties;
	I32			flags;
};

typedef struct PCB_Class PCB_Class;

/* Strucuture that keeps track of contexts */
struct PCB_Context {
	JSContext		*cx;	/* The JavaScript context which this instance belongs to */
	PCB_Function		*func_list;	/* Pointer to the first callback item that is registered */
	PCB_Class		*class_list;
	SV 			*error;
	struct PCB_Context	*next;		/* Pointer to the next created context */
	struct PCB_Runtime	*rt;
};

typedef struct PCB_Context PCB_Context;

struct PCB_Runtime {
	JSRuntime	*rt;
	PCB_Context	*list;
};

typedef struct PCB_Runtime PCB_Runtime;

/* Structure that keeps precompiled strict */
struct PCB_Script {
	PCB_Context		*cx;
	JSScript		*script;
};

typedef struct PCB_Script PCB_Script;

/* Defines */
static JSBool PCB_GetProperty(JSContext *, JSObject *, jsval, jsval *);
static JSBool PCB_SetProperty(JSContext *, JSObject *, jsval, jsval *);
static void PCB_Finalize(JSContext *, JSObject *);
static PCB_Context* PCB_NewContext();
static PCB_Context* PCB_GetContext(JSContext *);
SV* JSHASHToSV(JSContext *, JSObject *);
SV* JSARRToSV(JSContext *, JSObject *);
static JSBool JSVALToSV(JSContext *, JSObject *, jsval, SV**);
static JSBool SVToJSVAL(JSContext *, JSObject *, SV *, jsval *);

/* Context managing functions */
static PCB_Context *
PCB_NewContext() {
	PCB_Context *context;

	context = (PCB_Context *) calloc(1, sizeof(PCB_Context));

	return context;
}

static PCB_Context *
PCB_GetContext(JSContext *cx) {
	return (PCB_Context *) JS_GetContextPrivate(cx);

/*	while ( context ) {
		if(context->cx == cx) {
			return context;
		}

		context = context->next;
	}

	return NULL; */
}

static PCB_Function *
PCB_GetCallbackFunction(PCB_Context *cx, char *name) {
	PCB_Function *func;

	func = cx->func_list;

	while(func) {
		if(strcmp(func->js_native_name, name) == 0) {
			return func;
		}
		func = func->next;
	}

	return NULL;
}

static PCB_Class *
PCB_GetClass(PCB_Context *cx, char *name) {
	PCB_Class *ret = NULL;

	ret = cx->class_list;

	while(ret) {
		if(strcmp(ret->classname, name) == 0) {
			return ret;
		}

		ret = ret->next;
	}

	return NULL;
}

static PCB_Class *
PCB_GetClassByPackage(PCB_Context *cx, char *package) {
	PCB_Class *ret = NULL;

	ret = cx->class_list;

	while(ret) {
		if(ret->package != NULL) {
			if(strcmp(ret->package, package) == 0) {
				return ret;
			}
		}

		ret = ret->next;
	}

	return NULL;
}

static PCB_Method *
PCB_GetMethod(PCB_Class *cls, char *name) {
	PCB_Method *ret;

	ret = cls->methods;

	while(ret) {
		if(strcmp(ret->js_native_name, name) == 0) {
			return ret;
		}

		ret = ret->next;
	}

	return NULL;
}

static I32
PCB_GetPropertyFlags(PCB_Class *cls, char *name) {
	PCB_Property *prop;

	prop = cls->properties;

	while(prop) {
		if(strcmp(prop->name, name) == 0) {
			return prop->flags;
		}

		prop = prop->next;
	}

	return 0;
}

/* Universal call back for functions */
static JSBool
PCB_UniversalFunctionStub(JSContext *cx, JSObject *obj, uintN argc, jsval *argv, jsval *rval) {
	dSP;
	PCB_Function	*callback;
	PCB_Context	*context;
	JSFunction	*fun;
	SV		*sv;
	I32		ax;
	int		rcount;
	int		arg;
	
	fun = JS_ValueToFunction(cx, argv[-2]);

	if(!(context = PCB_GetContext(cx))) {
		croak("Can't get context\n");
	}

	if (! (callback = PCB_GetCallbackFunction(context, (char *) JS_GetFunctionName(fun)))) {
        	croak("Couldn't find perl callback");
	}

	if(SvROK(callback->pl_func_reference)) {
		if(SvTYPE(SvRV(callback->pl_func_reference)) == SVt_PVCV) {
			ENTER ;
			SAVETMPS ;
			PUSHMARK(SP) ;

		    for (arg = 0; arg < argc; arg++) {
		        sv = sv_newmortal();
		        JSVALToSV(cx, obj, argv[arg], &sv);
		        XPUSHs(sv);
		    }

			PUTBACK ;

			rcount = perl_call_sv(SvRV(callback->pl_func_reference), G_SCALAR);

			SPAGAIN ;

			if(rcount) {
				while(rcount--) {
					SV *rsv = POPs;
					
					SVToJSVAL(cx, obj, rsv, rval);
				}
			} else {
			}

			PUTBACK ;
			FREETMPS ;
			LEAVE ;
		} else {
		}
	} else {
	}
	
    return JS_TRUE;
}

static JSClass* 
PCB_NewStdJSClass(char *name) {	
	JSClass *jsc;

	jsc = (JSClass*) calloc(1, sizeof(JSClass));
	jsc->name = (char *) calloc(strlen(name), sizeof(char));
	strcpy(jsc->name, name);

	jsc->flags = JSCLASS_HAS_PRIVATE;
	jsc->addProperty = JS_PropertyStub;
	jsc->delProperty = JS_PropertyStub;  
	jsc->getProperty = PCB_GetProperty;  
	jsc->setProperty = PCB_SetProperty;
	jsc->enumerate = JS_EnumerateStub;
	jsc->resolve = JS_ResolveStub;
	jsc->convert = JS_ConvertStub;
	jsc->finalize = PCB_Finalize;

	return jsc;
}

static void
PCB_Finalize(JSContext *cx, JSObject *obj) {
	SV 	*priv;
	void	*priv_ptr = JS_GetPrivate(cx, obj);

	if(priv_ptr) {
		priv = (SV *) priv_ptr;

		SvREFCNT_dec(priv);
	}

}

/* Universal call back for functions */
static JSBool
PCB_InstancePerlClassStub(JSContext *cx, JSObject *obj, uintN argc, jsval *argv, jsval *rval) {
	PCB_Class		*pl_class;
	PCB_Context		*context;
	JSFunction		*fun;
	I32			rcount;
	int			arg;
	SV			*sv;
	JSClass			*jsclass;
	JSObject		*retobj;

	dSP ;

	fun = JS_ValueToFunction(cx, argv[-2]);

	if(!(context = PCB_GetContext(cx))) {

		croak("Can't get context\n");
	}

	if(!(pl_class = PCB_GetClass(context, (char *) JS_GetFunctionName(fun)))) {
		croak("Can't find class\n");
	}

	/* Extract constructor */
	jsclass = JS_GetClass(obj);

	/* Check if we are allowed to instanciate this class */
	if((pl_class->flags & JS_CLASS_NO_INSTANCE)) {
		JS_ReportError(cx, "Class '%s' can't be instanciated", jsclass->name);
		return JS_FALSE;
	}

	if(SvROK(pl_class->constructor)) {
		if(SvTYPE(SvRV(pl_class->constructor)) == SVt_PVCV) {
			ENTER ;
			SAVETMPS ;
			PUSHMARK(SP) ;

			for (arg = 0; arg < argc; arg++) {
				sv = sv_newmortal();
				JSVALToSV(cx, obj, argv[arg], &sv);
				XPUSHs(sv);
			}

			PUTBACK;

			rcount = perl_call_sv(SvRV(pl_class->constructor), G_SCALAR);

			SPAGAIN ;

			if(rcount) {
				while(rcount--) {
					SV *rsv = POPs;
					SvREFCNT_inc(rsv);
					JS_SetPrivate(cx, obj, (void *) rsv); 
				}
			} else {
				croak("no support for returning arrays yet");
			}	

			PUTBACK ;
			FREETMPS ;
			LEAVE ;
		} else {
		}
	} else {
	}

    return JS_TRUE;
}

static JSBool
PCB_MethodCallPerlClassStub(JSContext *cx, JSObject *obj, uintN argc, jsval *argv, jsval *rval) {
	PCB_Class		*pl_class;
	PCB_Context		*context;
	PCB_Method		*pl_method;
        JSFunction		*fun;
	I32			rcount;
	int			arg;
	SV			*sv;
	JSClass			*jsclass;
	SV *priv = (SV *) JS_GetPrivate(cx, obj);

	dSP ;

	fun = JS_ValueToFunction(cx, argv[-2]);


	if(!(context = PCB_GetContext(cx))) {
		croak("Can't get context\n");
	}

	jsclass = JS_GetClass(obj);

	if(!(pl_class = PCB_GetClass(context, jsclass->name))) {
		croak("Can't find class\n");
	}

	if(!(pl_method = PCB_GetMethod(pl_class, (char *) JS_GetFunctionName(fun)))) {
		croak("Can't find method\n");
	}


	if(SvROK(pl_method->pl_func_reference)) {
		if(SvTYPE(SvRV(pl_method->pl_func_reference)) == SVt_PVCV) {
			ENTER ;
			SAVETMPS ;
			PUSHMARK(SP) ;

			XPUSHs(priv);

			for (arg = 0; arg < argc; arg++) {
				sv = sv_newmortal();
				JSVALToSV(cx, obj, argv[arg], &sv);
				XPUSHs(sv);
			}

			PUTBACK ;

			rcount = perl_call_sv(SvRV(pl_method->pl_func_reference), G_SCALAR);

			SPAGAIN ;

			if(rcount) {
				while(rcount--) {
					SV *rsv = POPs;

					if(SvROK(rsv)) {
						if(SvRV(rsv) != SvRV(priv)) {
							SVToJSVAL(cx, obj, rsv, rval);
						}
					} else {
						SVToJSVAL(cx, obj, rsv, rval);
					}
				}
			} else {
				croak("no support for returning arrays yet");
			}

			PUTBACK ;
			FREETMPS ;
			LEAVE ;
		} else {
			croak("callback doesn't hold code reference 1");
		}
	} else {
		croak("callback doesn't hold reference 2\n");
	}

    return JS_TRUE;
}

static JSBool
PCB_GetProperty(JSContext *cx, JSObject *obj, jsval id, jsval *vp) {
	PCB_Context *context;
	PCB_Class   *pl_class;

	SV	*pobj;
	char	*keyname;
	JSClass	*jsclass;
	I32	flags;

	keyname = JS_GetStringBytes(JSVAL_TO_STRING(id));

	pobj = (SV *) JS_GetPrivate(cx, obj);

	if(SvROK(pobj)) {
		if(SvTYPE(SvRV(pobj)) == SVt_PVHV) {
			HV	*hv_obj;
			SV 	**keyval;

			hv_obj = (HV *) SvRV(pobj);

			if(hv_exists(hv_obj, keyname, strlen(keyname))) {
				/* Find property */
				if(sv_isobject(pobj)) {
					if(!(context = PCB_GetContext(cx))) {
						croak("Can't get context\n");
					}

					jsclass = JS_GetClass(obj);

					if(!(pl_class = PCB_GetClass(context, jsclass->name))) {
						croak("Can't find class\n");
					}

					flags = PCB_GetPropertyFlags(pl_class, keyname);

				}
	
				keyval = hv_fetch(hv_obj, keyname, strlen(keyname), 0);
				
				SVToJSVAL(cx, obj, *keyval, vp);
			}
		}
	}

	return JS_TRUE;
}



static JSBool
PCB_SetProperty(JSContext *cx, JSObject *obj, jsval id, jsval *vp) {
	PCB_Context *context;
	PCB_Class *pl_class;
	JSClass	*jsclass;
	SV	*pobj;
	char	*keyname;
	I32	flags;

	keyname = JS_GetStringBytes(JSVAL_TO_STRING(id));


	pobj = (SV *) JS_GetPrivate(cx, obj);

	if(SvROK(pobj)) {
		if(SvTYPE(SvRV(pobj)) == SVt_PVHV) {
			HV	*hv_obj;
			SV	*value = newSViv(0);
		
			hv_obj = (HV *) SvRV(pobj);

			if(hv_exists(hv_obj, keyname, strlen(keyname))) {
				/* Find property */
				if(sv_isobject(pobj)) {
					if(!(context = PCB_GetContext(cx))) {
						croak("Can't get context\n");
					}

					jsclass = JS_GetClass(obj);

					if(!(pl_class = PCB_GetClass(context, jsclass->name))) {
						croak("Can't find class\n");
					}

					flags = PCB_GetPropertyFlags(pl_class, keyname);

					if(flags & JS_PROP_READONLY) {
						JS_ReportError(cx, "Property '%s' is readonly\n", keyname);
						return JS_FALSE;
					}
				}

				JSVALToSV(cx, obj, *vp, &value);
				hv_store(hv_obj, keyname, strlen(keyname), value, 0);
			}
		}
	}
}

static void
PCB_AddPerlClass(PCB_Context *context, char *classname, SV *constructor, SV *methods, SV *properties, I32 gl_flags, char *pkname) {
	JSContext	*cx;
	PCB_Class	*perl_class;
	JSClass		*jsclass;
	JSFunctionSpec	*jsmethods;
	int 		idx = 0;

	if(context != NULL) {
		cx = context->cx;

		SvREFCNT_inc(constructor);

		perl_class = (PCB_Class *) calloc(1, sizeof(PCB_Class));

		perl_class->classname = (char *) calloc(strlen(classname) + 1, sizeof(char));
		perl_class->constructor = constructor;
	
		perl_class->methods = NULL;
		perl_class->properties = NULL;

		perl_class->flags = gl_flags;
		perl_class->package = NULL;

		if(pkname != NULL) {
			perl_class->package = (char *) calloc(strlen(pkname) + 1, sizeof(char));
			perl_class->package = strcpy(perl_class->package, pkname);
		}

		strcpy(perl_class->classname, classname);

		/* Create javascript class */
		jsclass = PCB_NewStdJSClass(classname);

		/* Add properties */
		{
			I32		hvlen;
			HE		*heelem;
			SV		*svelem;
			char		*keyname;
			I32		keylen;
			I32		flags;
			PCB_Property	*prop = NULL; 
							
			HV		*properties_hv = (HV *) SvRV(properties);

			hvlen = hv_iterinit(properties_hv);

			while((heelem = hv_iternext(properties_hv)) != NULL) {
				keyname	= hv_iterkey(heelem, &keylen);
				svelem = hv_iterval(properties_hv, heelem);

				if(SvIOK(svelem) && keylen) {
					if(SvIV(svelem) & (JS_PROP_PRIVATE | JS_PROP_READONLY)) {
						prop = (PCB_Property *) malloc(sizeof(PCB_Property));
					
						/* Copy the name of the property so we can identify it */
						prop->name = (char *) calloc(strlen(keyname), sizeof(char));
						strcpy(prop->name, keyname);

						/* Set flags to supplied value in properties hash */
						prop->flags = SvIV(svelem);
			
						prop->next = perl_class->properties;
						perl_class->properties = prop;
					}
				}
			}
		}
	
		/* Create method spec array */
		if(SvROK(methods)) {
			if(SvTYPE(SvRV(methods)) == SVt_PVHV) {
				I32				hvlen;
				HE				*heelem;
				SV				*svelem;
				char			*keyname;
				I32				keylen;
				int				methods_cnt = 0;

				HV *methods_hv = (HV *) SvRV(methods);

				hvlen = hv_iterinit(methods_hv);

				
				/* Count number of valid methods */
				while((heelem = hv_iternext(methods_hv)) != NULL) {
					keyname = hv_iterkey(heelem, &keylen);
					svelem = hv_iterval(methods_hv, heelem);

					if(SvROK(svelem)) {
						if(SvTYPE(SvRV(svelem)) == SVt_PVCV) {
							/* Woohoo, code reference */

							methods_cnt++;
						}
					}
				}

				/* Set index to zero */
				idx = 0;

				if(methods_cnt) {
					/* Assume all keys are code references */
					jsmethods = (JSFunctionSpec *) calloc(methods_cnt + 1, sizeof(JSFunctionSpec));

					/* Add methods */
					hvlen = hv_iterinit(methods_hv);

					/* Cound number of valid methods */
					while((heelem = hv_iternext(methods_hv)) != NULL) {
						keyname = hv_iterkey(heelem, &keylen);
						svelem = hv_iterval(methods_hv, heelem);

						if(SvROK(svelem)) {
							if(SvTYPE(SvRV(svelem)) == SVt_PVCV) {
								JSFunctionSpec *spec;
								PCB_Method	   *pmethod;
								spec = &jsmethods[idx];
								/* Woohoo, code reference */

								spec->name = (char *) calloc(strlen(keyname), sizeof(char));
								spec->name = strcpy((char *)spec->name, keyname);
		

								spec->call = PCB_MethodCallPerlClassStub;
								spec->nargs = 0;
								spec->flags = 0;
								spec->extra = 0;

								idx++;

								/* Add the perl callback */
								SvREFCNT_inc(svelem);

								pmethod = (PCB_Method *) calloc(1, sizeof(PCB_Method));

								pmethod->js_native_name = (char *) calloc(strlen(keyname), sizeof(char));
								pmethod->js_native_name = strcpy(pmethod->js_native_name, keyname);
								pmethod->pl_func_reference = svelem;
								pmethod->next = perl_class->methods;
								perl_class->methods = pmethod;
							}
						}
					}
				}

				/* Add an empty def at the end */
				(jsmethods[idx]).name = NULL;
				(jsmethods[idx]).call = NULL;
				(jsmethods[idx]).nargs = 0;
				(jsmethods[idx]).flags = 0;
				(jsmethods[idx]).extra = 0;
			}
		}

		perl_class->jsclass = jsclass;
		perl_class->base_obj = JS_InitClass(cx, JS_GetGlobalObject(cx), NULL, perl_class->jsclass, PCB_InstancePerlClassStub, 0, NULL, jsmethods, NULL, NULL);
		if(perl_class->base_obj == NULL) {
		}

		perl_class->next = context->class_list;
	
		context->class_list = perl_class;
	}
}

/* Perl Callback functions */
static void
PCB_AddCallbackFunction(PCB_Context *context, char *name, SV *pl_func) {
	JSContext *cx;
	PCB_Function *func;
	
	if(context != NULL) {
		cx = context->cx;		

		/* Allocate memory for a new callback */
		func = (PCB_Function *) calloc(1, sizeof(PCB_Function));

		/* Allocate memory for the native name */
		func->js_native_name = (char *) calloc(strlen(name) + 1, sizeof(char));
		strcpy(func->js_native_name, name);
		func->pl_func_reference = pl_func;

		func->next = context->func_list;
		context->func_list = func;

		/* Add refcount to perl subroutine */
		SvREFCNT_inc(pl_func);

		/* Add the function to the javascript context */
		JS_DefineFunction(cx, JS_GetGlobalObject(cx), name, PCB_UniversalFunctionStub, 0, 0);
	} else {
		croak("Can't find context\n");
	}
}

/* Converts perl values to equivalent JavaScript values */
static JSBool
SVToJSVAL(JSContext *cx, JSObject *obj, SV *ref, jsval *rval) {
	if(sv_isobject(ref)) {
		PCB_Context *pcx;
		PCB_Class	*pjsc;
		JSObject	*newobj;
		HV	*stash = SvSTASH(SvRV(ref));
		char 	*name = HvNAME(stash);

		if(!(pcx = PCB_GetContext(cx))) {
			return JS_FALSE;
		}

		if(!(pjsc = PCB_GetClassByPackage(pcx, name))) {
			return JS_FALSE;
		}

		SvREFCNT_inc(ref);
		
		newobj = JS_NewObject(cx, pjsc->jsclass, NULL, obj);
		
		JS_SetPrivate(cx, newobj, (void *) ref);

		*rval = OBJECT_TO_JSVAL(newobj);

		return JS_TRUE;
	}

	
	if(SvTYPE(ref) == SVt_NULL) {
		/* Returned value is undefined */
		*rval = JSVAL_VOID;
	} else if(SvIOK(ref)) {
		/* Returned value is an integer */
		*rval = INT_TO_JSVAL(SvIV(ref));
	} else if(SvNOK(ref)) {
		JS_NewDoubleValue(cx, SvNV(ref), rval);
	} else if(SvPOK(ref)) {
		/* Returned value is a string */
		char *str;
		STRLEN len;

		str = SvPV(ref, len);
	
		*rval = STRING_TO_JSVAL(JS_NewStringCopyN(cx, str, len));
	} else if(SvROK(ref)) {
		I32	type;

		type = SvTYPE(SvRV(ref));
		/* Most likely it's an hash that is returned */
		if(type == SVt_PVHV) {
			HV			*hv = (HV *) SvRV(ref);
			JSObject	*new_obj;
			JSClass		*jsclass;

			new_obj = JS_NewObject(cx, NULL, NULL, NULL);

			if(new_obj == NULL) {
				croak("couldn't create new object\n");
			} else {
				/* Assign properties, lets iterate over the hash */
				I32		items;
				HE		*key;
				char	*keyname;
				I32		keylen;
				SV		*keyval;
				jsval	elem;
					
				items = hv_iterinit(hv);

				while((key = hv_iternext(hv)) != NULL) {
					keyname = hv_iterkey(key, &keylen);
					keyval = (SV *) hv_iterval(hv, key);

					SVToJSVAL(cx, obj, keyval, &elem);

					if(!JS_DefineProperty(cx, new_obj, keyname, elem, NULL, NULL, JSPROP_ENUMERATE)) {
					}
				}

				*rval = OBJECT_TO_JSVAL(new_obj);
			}
		} else if(type == SVt_PVAV) {
			/* Then it's probablly an array */
			AV			*av = (AV *) SvRV(ref);
			jsint		av_length;
			int			cnt;
			jsval		*elems;
			JSObject	*arr_obj;

			av_length = av_len(av);
			elems = (jsval *) calloc(av_length + 1, sizeof(jsval));

			for(cnt = av_length + 1; cnt > 0; cnt--) {
				SVToJSVAL(cx, obj, av_pop(av), &(elems[cnt - 1]));
			}

			arr_obj = JS_NewArrayObject(cx, av_length + 1, elems);

			*rval = OBJECT_TO_JSVAL(arr_obj);
		} else if(type == SVt_PVGV) {

			*rval = PRIVATE_TO_JSVAL(ref);
		} else if(type == SVt_PV || type == SVt_IV || type == SVt_NV || type == SVt_RV) {
			/* Not very likely to return a reference to a primitive type, but we need to support that aswell */
			
		}
	}

	return JS_TRUE;
}
/* Converts a JavaScript value to equivalent Perl value */
static JSBool
JSVALToSV(JSContext *cx, JSObject *obj, jsval v, SV** sv)
{
	if(JSVAL_IS_PRIMITIVE(v)){
        if(JSVAL_IS_NULL(v) || JSVAL_IS_VOID(v)){
            *sv = &PL_sv_undef;
        } else if(JSVAL_IS_INT(v)){
            sv_setiv(*sv, JSVAL_TO_INT(v));
        } else if(JSVAL_IS_DOUBLE(v)){
            sv_setnv(*sv, *JSVAL_TO_DOUBLE(v));
        } else if(JSVAL_IS_STRING(v)){
            sv_setpv(*sv, JS_GetStringBytes(JSVAL_TO_STRING(v)));
        } else {

            warn("Unknown primitive type");
        }
    } else {
		if(JSVAL_IS_OBJECT(v)) {
			JSObject *object = JSVAL_TO_OBJECT(v);

			if(JS_IsArrayObject(cx, object)) {
				SV *arr_sv;

				arr_sv = JSARRToSV(cx, object);

				sv_setsv(*sv, arr_sv);
			} else {
				SV *hash_sv;

				hash_sv = JSHASHToSV(cx, object);

				sv_setsv(*sv, hash_sv);
			}
		}
	}

    return JS_TRUE;
}

/* Converts an JavaScript array object to an Perl array reference */
SV *
JSARRToSV(JSContext *cx, JSObject *object)
{
	AV			*av;
	SV			*sv;

	jsuint		jsarrlen;
	jsuint		index;
	jsval		elem;

	av = newAV();
		
	JS_GetArrayLength(cx, object, &jsarrlen);

	for(index = 0; index < jsarrlen; index++) {
		JS_GetElement(cx, object, index, &elem);
	
		if(JSVAL_IS_PRIMITIVE(elem)) {
			if(JSVAL_IS_NULL(elem) || JSVAL_IS_VOID(elem)) {
				av_push(av, &PL_sv_undef);
			} else if(JSVAL_IS_INT(elem)) {
				av_push(av, newSViv(JSVAL_TO_INT(elem)));
			} else if(JSVAL_IS_DOUBLE(elem)) {
				av_push(av, newSVnv(*JSVAL_TO_DOUBLE(elem)));
			} else if(JSVAL_IS_STRING(elem)) {
				av_push(av, newSVpv(JS_GetStringBytes(JSVAL_TO_STRING(elem)), 0));
			} 
		} else {
			if(JSVAL_IS_OBJECT(elem)) {
				JSObject *lobject = JSVAL_TO_OBJECT(elem);

				if(JS_IsArrayObject(cx, lobject)) {
					av_push(av, JSARRToSV(cx, lobject));
				} else {
					av_push(av, JSHASHToSV(cx, lobject));
				}
			}
		}
	}

	sv = newRV_inc((SV *) av);

	return sv;
}

/* Converts a JavaScript object (not array) to a anonymous perl hash reference */
SV *
JSHASHToSV(JSContext *cx, JSObject *object)
{
	HV			*hv;
	SV			*sv;
	JSIdArray		*prop_arr;
	int			idx;
	jsval			elem;

	prop_arr = JS_Enumerate(cx, object);

	hv = newHV();

	for(idx = 0; idx < prop_arr->length; idx++) {
		jsval		key;

		JS_IdToValue(cx, (prop_arr->vector)[idx], &key);

		if(JSVAL_IS_STRING(key)) {
			jsval		value;
			char		*js_key = JS_GetStringBytes(JSVAL_TO_STRING(key));

			JS_GetProperty(cx, object, js_key, &value);

			if(JSVAL_IS_PRIMITIVE(value)) {
				if(JSVAL_IS_NULL(value) || JSVAL_IS_VOID(value)) {
					hv_store(hv, js_key, strlen(js_key), &PL_sv_undef, 0);
				} else if(JSVAL_IS_INT(value)) {
					hv_store(hv, js_key, strlen(js_key), newSViv(JSVAL_TO_INT(value)), 0);
				} else if(JSVAL_IS_DOUBLE(value)) {
					hv_store(hv, js_key, strlen(js_key), newSVnv(*JSVAL_TO_DOUBLE(value)), 0);
				} else if(JSVAL_IS_STRING(value)) {
					hv_store(hv, js_key, strlen(js_key), newSVpv(JS_GetStringBytes(JSVAL_TO_STRING(value)), 0), 0);
				} 
			} else {
				if(JSVAL_IS_OBJECT(value)) {
					JSObject *lobject = JSVAL_TO_OBJECT(value);

					if(JS_IsArrayObject(cx, lobject)) {
						hv_store(hv, js_key, strlen(js_key), JSARRToSV(cx, lobject), 0);
					} else {
						hv_store(hv, js_key, strlen(js_key), JSHASHToSV(cx, lobject), 0);
					}
				}
			}
		}
	}

	JS_DestroyIdArray(cx, prop_arr);

	sv = newRV_inc((SV *) hv);

	return sv;
}

/* Error rapporting */
static void
PCB_ErrorReporter(JSContext *cx, const char *message, JSErrorReport *report) {
	fprintf(stderr, "%s at line %d: %s\n", message, report->lineno, report->linebuf);

/*	PCB_Context *context;
	SV	    *errfunc;

	dSP;

	context = PCB_GetContext(cx);

	if(context != null) {
		errfunc = context->error;

		ENTER ;
		SAVETMPS ;
		PUSHMARK(SP) ;
		XPUSHs(newSVpv(message, strlen(message));
		XPUSHs(newSViv(report->lineno);
		XPUSHs(newSVpv(report->linebuf, strlen(report->linebuf));
		PUTBACK;

		perl_call_sv(SvRV(context->error), G_SCALAR);
	} */
}

/* Calls a Perl function which is bound to a JavaScript function */
void
InitContexts() {
}

MODULE = JavaScript		PACKAGE = JavaScript			PREFIX = js_
PROTOTYPES: DISABLE

char *
js_GetEngineVersion()
	CODE:
	{
		RETVAL = (char *) JS_GetImplementationVersion();
	}
	OUTPUT:
	RETVAL

BOOT:
InitContexts();

MODULE = JavaScript		PACKAGE = JavaScript::Runtime	PREFIX = jsr_

PCB_Runtime *
jsr_CreateRuntime(maxbytes)
	int maxbytes
	PREINIT:
		PCB_Runtime *rt;
	CODE:
		Newz(1, rt, 1, PCB_Runtime);
		if(rt == NULL) {
			croak("Can't create runtime");
			XSRETURN_UNDEF;
		}

		rt->rt = JS_NewRuntime(maxbytes);
		if(rt->rt == NULL) {
			croak("Can't create runtime");
			XSRETURN_UNDEF;
		}

		RETVAL = rt;
	OUTPUT:
		RETVAL

void
jsr_DestroyRuntime(rt)
	PCB_Runtime *rt

	CODE:
		if(SvREFCNT(ST(0)) == 1) {
			JS_DestroyRuntime(rt->rt);
			Safefree(rt);
		} else {
			warn("To many references to runtime");
		}

MODULE = JavaScript		PACKAGE = JavaScript::Context	PREFIX = jsc_

PCB_Context *
jsc_CreateContext(rt, stacksize)
	PCB_Runtime	*rt;
	int		stacksize;
	PREINIT:
		PCB_Context	*cx;
		JSObject	*obj;
	CODE:
		Newz(1, cx, 1, PCB_Context);

		cx->cx = JS_NewContext(rt->rt, stacksize);

		if(cx->cx == NULL) {
			Safefree(cx);
			croak("Can't create context");
			XSRETURN_UNDEF;
		}

		obj = JS_NewObject(cx->cx, &global_class, NULL, NULL);
		JS_InitStandardClasses(cx->cx, obj);

		/* Add context to context list */
		cx->func_list = NULL;
		cx->class_list = NULL;
		cx->rt = rt;
		cx->next = rt->list;
	        rt->list = cx;

		JS_SetContextPrivate(cx->cx, (void *)cx);
		JS_SetErrorReporter(cx->cx, PCB_ErrorReporter);

		RETVAL = cx;
	OUTPUT:
	RETVAL

void
jsc_SetErrorCallbackImpl(cx, function)
	PCB_Context	*cx;
	SV		*function;

	CODE:
		if(!SvROK(function)) {
			croak("Callback is not a reference\n");
		} else {
			if(SvTYPE(SvRV(function)) == SVt_PVCV) {
				cx->error = function;
			} else {
				croak("Callback is not a code reference\n");
			}
		}

void
jsc_BindPerlFunctionImpl(cx, name, function)
	PCB_Context	*cx;
	char		*name;
	SV		*function

	CODE:
		if(!SvROK(function)) {
			croak("Not a reference\n");
		} else {
			if(SvTYPE(SvRV(function)) == SVt_PVCV) {
				PCB_AddCallbackFunction(cx, name, function);
			} else {
				croak("Not a code reference\n");
			}
		}

int
jsc_BindPerlClassImpl(cx, classname, constructor, methods, properties, package, flags)
	PCB_Context	*cx;
	char		*classname;
	SV		*constructor;
	SV		*methods;
	SV		*properties;
	SV		*package;
	SV		*flags;

	PREINIT:
		char	*pkname = NULL;
	CODE:
		if(SvTRUE(package) && SvPOK(package)) {
			pkname = SvPV_nolen(package);
		}

		PCB_AddPerlClass(cx, classname, constructor, methods, properties, SvIV(flags), pkname);
		RETVAL = 1;
	OUTPUT:
		RETVAL

int
jsc_BindPerlObject(cx, name, object)
	PCB_Context	*cx;
	char		*name;
	SV		*object;
	CODE:
		if(SvTYPE(object) == SVt_RV) {
			if(sv_isobject(object)) {
				PCB_Class	*pjsc;
				JSObject	*jsobj;
				HV		*stash = SvSTASH(SvRV(object));
				char	 	*pname = HvNAME(stash);

				if(!(pjsc = PCB_GetClassByPackage(cx, pname))) {
					croak("Missing class definition");
				}

				SvREFCNT_inc(object);

				jsobj = JS_DefineObject(cx->cx, JS_GetGlobalObject(cx->cx), name, pjsc->jsclass, NULL, JSPROP_READONLY);

				if(jsobj != NULL) {
					JS_SetPrivate(cx->cx, jsobj, (void *) object);
				}

				RETVAL = 1;
			} else {
				croak("Object is not an object");
			}
		} else {
			croak("Object is not an reference\n");
		}
	OUTPUT:
		RETVAL

jsval 
jsc_EvaluateScriptImpl(cx, script)
	PCB_Context	*cx;
	char		*script;
	PREINIT:
		jsval	rval;
	CODE:
		if(!JS_EvaluateScript(cx->cx, JS_GetGlobalObject(cx->cx), script, strlen(script), "Perl", 0, &rval)) {
			XSRETURN_UNDEF;
		}

		JS_GC(cx->cx);

		RETVAL = rval;
	OUTPUT:
		RETVAL

jsval
jsc_CallFunctionImpl(cx, func_name, args)
	PCB_Context	*cx;
	char		*func_name;
	SV		*args;
	PREINIT:
		jsval		rval;
		int		av_length;
		jsval		*arg_list;
		AV		*av;
		int		cnt;
		SV		*val;
	CODE:
		av = (AV *) SvRV(args);
		av_length = av_len(av);
		arg_list = (jsval *) calloc(av_length + 1, sizeof(jsval));

		for(cnt = av_length + 1; cnt > 0; cnt--) {
			val = av_pop(av);
			SVToJSVAL(cx->cx, JS_GetGlobalObject(cx->cx), val, &(arg_list[cnt - 1]));
		}

		if(!JS_CallFunctionName(cx->cx, JS_GetGlobalObject(cx->cx), func_name, av_length + 1, arg_list, &rval)) {
			fprintf(stderr, "Error in call\n");
			XSRETURN_UNDEF;
		}

		JS_GC(cx->cx);

		RETVAL = rval;
	OUTPUT:
		RETVAL

int
jsc_CanFunctionImpl(cx, func_name)
	PCB_Context	*cx;
	char		*func_name;
	PREINIT:
		jsval	vl;
	CODE:
		if(JS_GetProperty(cx->cx, JS_GetGlobalObject(cx->cx), func_name, &vl)) {
			if(JS_ValueToFunction(cx->cx, vl) != NULL) {
				RETVAL = 1;
			} else {
				RETVAL = 0;
			}
		} else {
			RETVAL = 0;
		}
	OUTPUT:
		RETVAL


MODULE = JavaScript		PACKAGE = JavaScript::Script	PREFIX = jss_

jsval
jss_ExecuteScriptImpl(psc)
	PCB_Script *psc;
	PREINIT:
		PCB_Context *cx;
		jsval rval;
	CODE:
		cx = psc->cx;
		if(!JS_ExecuteScript(cx->cx, JS_GetGlobalObject(cx->cx), psc->script, &rval)) {
			XSRETURN_UNDEF;
		}
		RETVAL = rval;
	OUTPUT:
		RETVAL

PCB_Script *
jss_CompileScriptImpl(cx, source)
	PCB_Context	*cx;
	char		*source;
	PREINIT:
		PCB_Script	*psc;
		JSScript 	*script;
		uintN		line;
	CODE:
		psc = (PCB_Script *) calloc(1, sizeof(PCB_Script));

		if(psc == NULL) {
			fprintf(stderr, "Can't create script\n");
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
