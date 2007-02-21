#include "JavaScript_Env.h"

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

struct PJS_InterruptHandler {
    JSTrapHandler               handler;
    void                        *data;
    
    /* Private field, don't mess with it */
    struct PJS_InterruptHandler *_next;
};

typedef struct PJS_InterruptHandler PJS_InterruptHandler;

struct PJS_Runtime {
    JSRuntime 	            *rt;
    PJS_Context	            *list;
    PJS_InterruptHandler 	*interrupt_handlers;

	/* Extension field that can be used by subclasses */
};

typedef struct PJS_Runtime PJS_Runtime;


/* Structure that keeps precompiled strict */
struct PJS_Script {
    PJS_Context *cx;
    JSScript *script;
};

typedef struct PJS_Script PJS_Script;
