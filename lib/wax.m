//
//  ObjLua.m
//  Lua
//
//  Created by ProbablyInteractive on 5/27/09.
//  Copyright 2009 Probably Interactive. All rights reserved.
//

#ifndef WAX_TARGET_OS_WATCH
#warning "compile not for TARGET_OS_WATCH"

#import "ProtocolLoader.h"
#endif
#import "wax.h"
#import "wax_class.h"
#import "wax_instance.h"
#import "wax_struct.h"
#import "wax_helpers.h"
#import "wax_gc.h"
#import "wax_server.h"
#import "wax_stdlib.h"

#import "lauxlib.h"
#import "lobject.h"
#import "lualib.h"
#import "wax_define.h"
static void addGlobals(lua_State *L);
static int waxRoot(lua_State *L);
static int waxPrint(lua_State *L);
static int tolua(lua_State *L);
static int toobjc(lua_State *L);
static int exitApp(lua_State *L);
static int objcDebug(lua_State *L);

extern int luaCallBlockReturnObjectWithObjectParam(lua_State *L);
extern int luaCallBlockReturnVoidWithObjectParam(lua_State *L);
extern int luaCallBlockWithParamsTypeArray(lua_State *L);
extern int luaCallBlockWithParamsTypeEncoding(lua_State *L);
extern int luaCallBlock(lua_State *L);

extern int luaSetWaxConfig(lua_State *L);

//runtime error
static void (*wax_luaRuntimeErrorHandler)(NSString *reason, BOOL willExit);

static lua_State *currentL;
lua_State *wax_currentLuaState() {
    
    if (!currentL) 
        currentL = lua_open();
    
    return currentL;
}

void wax_uncaughtExceptionHandler(NSException *e) {
    NSLog(@"ERROR: Uncaught exception %@", [e description]);
    lua_State *L = wax_currentLuaState();
    
    if (L) {
        wax_getStackTrace(L);
        const char *stackTrace = luaL_checkstring(L, -1);
        NSLog(@"%s", stackTrace);
        lua_pop(L, -1); // remove the stackTrace
    }
}

int wax_panic(lua_State *L) {
	printf("Lua panicked and quit: %s\n", luaL_checkstring(L, -1));
    NSString *reason = [NSString stringWithFormat:@"Lua panicked and quit: %s\n", luaL_checkstring(L, -1)];
    if(wax_luaRuntimeErrorHandler){
        wax_luaRuntimeErrorHandler(reason, YES);
    }
    NSException *e = [NSException exceptionWithName:@"wax_panic" reason:reason userInfo:nil];
    [e raise];
	exit(EXIT_FAILURE);
}

lua_CFunction lua_atpanic (lua_State *L, lua_CFunction panicf);

void wax_setup() {
//	NSSetUncaughtExceptionHandler(&wax_uncaughtExceptionHandler);//let it catched by outside crash handler
	
    NSFileManager *fileManager = [NSFileManager defaultManager];
    [fileManager changeCurrentDirectoryPath:[[NSBundle mainBundle] bundlePath]];
    
    lua_State *L = wax_currentLuaState();
	lua_atpanic(L, &wax_panic);
    
    luaL_openlibs(L); 

	luaopen_wax_class(L);
    luaopen_wax_instance(L);
    luaopen_wax_struct(L);
	
    addGlobals(L);
	
	[wax_gc start];
}

void wax_startWithNil(){
    wax_start(nil, nil);
}

void wax_start(char* initScript, lua_CFunction extensionFunction, ...) {
    
	wax_setup();
	
	lua_State *L = wax_currentLuaState();
	
	// Load extentions
	// ---------------
	if (extensionFunction) {
        extensionFunction(L);
		
        va_list ap;
        va_start(ap, extensionFunction);
        while((extensionFunction = va_arg(ap, lua_CFunction))) extensionFunction(L);
		
        va_end(ap);
    }

	// Load stdlib
	// ---------------
	#ifdef WAX_STDLIB 
		// If the stdlib was autogenerated and included in the source, load
		char stdlib[] = WAX_STDLIB;
		size_t stdlibSize = sizeof(stdlib);
	#else 
		char stdlib[] = "require 'wax'";
		size_t stdlibSize = strlen(stdlib);
	#endif
    
//    for(int i = 0; i < stdlibSize; ++i){
//        printf("%d,", stdlib[i]);
//    }
    
	if (luaL_loadbuffer(L, stdlib, stdlibSize, "loading wax stdlib") || lua_pcall(L, 0, LUA_MULTRET, 0)) {
		fprintf(stderr,"Error opening wax scripts: %s\n", lua_tostring(L,-1));
	}
//    if (luaL_loadfile(L, "/Users/junzhan/Documents/macpro-data/project/all_github/wax/examples/States_nof/wax.dat副本") || lua_pcall(L, 0, LUA_MULTRET, 0)) {
//        fprintf(stderr,"Error opening wax scripts: %s\n", lua_tostring(L,-1));
//    }
    
	// Run Tests or the REPL?
	// ----------------------
	NSDictionary *env = [[NSProcessInfo processInfo] environment];
    if ([[env objectForKey:@"WAX_TEST"] isEqual:@"YES"]) {
		printf("Running Tests\n");
		if (luaL_dostring(L, "require 'tests'") != 0) {
			fprintf(stderr,"Fatal error running tests: %s\n", lua_tostring(L,-1));
        }
//        exit(1);
    }
	else if ([[env objectForKey:@"WAX_REPL"] isEqual:@"YES"]) {
		printf("Starting REPL\n");
		if (luaL_dostring(L, "require 'wax.repl'") != 0) {
            fprintf(stderr,"Fatal error starting the REPL: %s\n", lua_tostring(L,-1));
        }
//		exit(1);
	}
	else {
		// Load app
		char appLoadString[512];
        if(initScript){//if no script then do not load, To avoid security problems
            snprintf(appLoadString, sizeof(appLoadString), "local f = '%s' require(f:gsub('%%.[^.]*$', ''))", initScript); // Strip the extension off the file.
            if (luaL_dostring(L, appLoadString) != 0) {
                fprintf(stderr,"Error opening wax scripts: %s\n", lua_tostring(L,-1));
            }
        }
	}

}

void wax_startWithServer() {		
	wax_setup();
    
#ifndef WAX_TARGET_OS_WATCH
#warning "compile not for TARGET_OS_WATCH"
	[wax_server class]; // You need to load the class somehow via the wax.framework
#endif
	lua_State *L = wax_currentLuaState();
	
	// Load all the wax lua scripts
    if (luaL_dofile(L, WAX_SCRIPTS_DIR "/scripts/wax/init.lua") != 0) {
        fprintf(stderr,"Fatal error opening wax scripts: %s\n", lua_tostring(L,-1));
    }
	
	Class WaxServer = objc_getClass("WaxServer");
	if (!WaxServer) [NSException raise:@"Wax Server Error" format:@"Could load Wax Server"];
	
	[WaxServer start];
}

void wax_end() {
    [wax_gc stop];
    lua_close(wax_currentLuaState());
    currentL = 0;
}

static void addGlobals(lua_State *L) {
    lua_getglobal(L, "wax");
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1); // Get rid of the nil
        lua_newtable(L);
        lua_pushvalue(L, -1);
        lua_setglobal(L, "wax");
    }
    
    lua_pushnumber(L, WAX_VERSION);
    lua_setfield(L, -2, "version");
    
    lua_pushstring(L, [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] UTF8String]);
    lua_setfield(L, -2, "appVersion");
    
    lua_pushcfunction(L, waxRoot);
    lua_setfield(L, -2, "root");

    lua_pushcfunction(L, waxPrint);
    lua_setfield(L, -2, "print");    
    
#ifdef DEBUG
    lua_pushboolean(L, YES);
    lua_setfield(L, -2, "isDebug");
#endif
    
#if WAX_IS_ARM_64 == 1
    lua_pushboolean(L, YES);
    lua_setfield(L, -2, "isArm64");
#endif
    
    lua_pop(L, 1); // pop the wax global off
    

    lua_pushcfunction(L, tolua);
    lua_setglobal(L, "tolua");
    

#pragma mark block

    lua_pushcfunction(L, luaCallBlockWithParamsTypeArray);
    lua_setglobal(L, "luaCallBlockWithParamsTypeArray");

    lua_pushcfunction(L, luaCallBlock);
    lua_setglobal(L, "luaCallBlock");

    
    
    lua_pushcfunction(L, luaSetWaxConfig);
    lua_setglobal(L, "luaSetWaxConfig");
    
#pragma mark other
    
    lua_pushcfunction(L, toobjc);
    lua_setglobal(L, "toobjc");
    
    lua_pushcfunction(L, exitApp);
    lua_setglobal(L, "exitApp");
    
    lua_pushstring(L, [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0] UTF8String]);
    lua_setglobal(L, "NSDocumentDirectory");
    
    lua_pushstring(L, [[NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) objectAtIndex:0] UTF8String]);
    lua_setglobal(L, "NSLibraryDirectory");
    
    NSString *cachePath = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    lua_pushstring(L, [cachePath UTF8String]);
    lua_setglobal(L, "NSCacheDirectory");

    NSError *error = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:cachePath withIntermediateDirectories:YES attributes: nil error:&error];
    if (error) {
        wax_log(LOG_DEBUG, @"Error creating cache path. %@", [error localizedDescription]);
    }
}

static int waxPrint(lua_State *L) {
    fprintf(stderr, "%s\n", luaL_checkstring(L, 1));//use fprintf , avoid empty by macro
    return 0;
}

static int waxRoot(lua_State *L) {
    luaL_Buffer b;
    luaL_buffinit(L, &b);
    luaL_addstring(&b, WAX_SCRIPTS_DIR);
    
    for (int i = 1; i <= lua_gettop(L); i++) {
        luaL_addstring(&b, "/");
        luaL_addstring(&b, luaL_checkstring(L, i));
    }

    luaL_pushresult(&b);
                       
    return 1;
}

static int tolua(lua_State *L) {
    if (lua_isuserdata(L, 1)) { // If it's not userdata... it's already lua!
        wax_instance_userdata *instanceUserdata = (wax_instance_userdata *)luaL_checkudata(L, 1, WAX_INSTANCE_METATABLE_NAME);
        wax_fromInstance(L, instanceUserdata->instance);
    }
    
    return 1;
}

static int toobjc(lua_State *L) {
    id *instancePointer = wax_copyToObjc(L, "@", 1, nil);
    id instance = *(id *)instancePointer;
    
    wax_instance_create(L, instance, NO);
    
    if (instancePointer) free(instancePointer);
    
    return 1;
}

static int exitApp(lua_State *L) {
    exit(0);
    return 0;
}


#pragma mark run
int wax_runLuaString(const char *script){
    [wax_globalLock() lock];
    int i = luaL_dostring(wax_currentLuaState(), script);
    [wax_globalLock() unlock];
    return i;
}

int wax_runLuaFile(const char *script){
    [wax_globalLock() lock];
    int i = luaL_dofile(wax_currentLuaState(), script);
    [wax_globalLock() unlock];
    return i;
}


int wax_runLuaByteCode(NSData *data, NSString *name){
    [wax_globalLock() lock];
    
    lua_State *L = wax_currentLuaState();
    int i = (luaL_loadbuffer(L, [data bytes], data.length, [name cStringUsingEncoding:NSUTF8StringEncoding]) || lua_pcall(L, 0, LUA_MULTRET, 0));
    if(i){
        NSString *error = [NSString stringWithFormat:@"run patch failed: %s", lua_tostring(wax_currentLuaState(), -1)];
        NSLog(@"error = %@", error);
    }
    
    [wax_globalLock() unlock];
    return i;
}

#pragma mark lua runtime handler

void wax_setLuaRuntimeErrorHandler(void (*handler)(NSString *reason, BOOL willExit)){
    wax_luaRuntimeErrorHandler = handler;
}
WaxLuaRuntimeErrorHandler wax_getLuaRuntimeErrorHandler(){
    return wax_luaRuntimeErrorHandler;
}