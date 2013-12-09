//
//  MOUtilities.m
//  Mocha
//
//  Created by Logan Collins on 5/11/12.
//  Copyright (c) 2012 Sunflower Softworks. All rights reserved.
//

#import "MOUtilities.h"

#import "MORuntime_Private.h"

#import "MOFunctionArgument.h"
#import "MOMethod_Private.h"
#import "MOUndefined.h"
#import "MOPointerValue.h"
#import "MOPointer.h"

#import "MOBridgeSupportController.h"
#import "MOBridgeSupportSymbol.h"

#import "MOBox.h"
#import "MOAllocator.h"

#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>


#pragma mark -
#pragma mark Values

JSValueRef MOJSValueToType(JSContextRef ctx, JSObjectRef objectJS, JSType type, JSValueRef *exception) {
    MOBox *box = (__bridge MOBox *)(JSObjectGetPrivate(objectJS));
    if (box != nil) {
        // Boxed object
        id object = [box representedObject];
        
        if ([object isKindOfClass:[NSString class]]) {
            JSStringRef string = JSStringCreateWithCFString((__bridge CFStringRef)object);
            JSValueRef value = JSValueMakeString(ctx, string);
            JSStringRelease(string);
            return value;
        }
        else if ([object isKindOfClass:[NSNumber class]]) {
            double doubleValue = [object doubleValue];
            return JSValueMakeNumber(ctx, doubleValue);
        }
        
        // Convert the object's description to a string as a last ditch effort
        NSString *description = [object description];
        JSStringRef string = JSStringCreateWithCFString((__bridge CFStringRef)description);
        JSValueRef value = JSValueMakeString(ctx, string);
        JSStringRelease(string);
        return value;
    }
    return NULL;
}

NSString * MOJSValueToString(JSContextRef ctx, JSValueRef value, JSValueRef *exception) {
    if (value == NULL) {
        return nil;
    }
    JSStringRef resultStringJS = JSValueToStringCopy(ctx, value, exception);
    NSString *resultString = (NSString *)CFBridgingRelease(JSStringCopyCFString(kCFAllocatorDefault, resultStringJS));
    JSStringRelease(resultStringJS);
    return resultString;
}


#pragma mark -
#pragma mark Invocation

JSValueRef MOSelectorInvoke(id target, SEL selector, JSContextRef ctx, size_t argumentCount, const JSValueRef arguments[], JSValueRef *exception) {
    MORuntime *runtime = [MORuntime runtimeWithContext:ctx];
    
    NSMethodSignature *methodSignature = [target methodSignatureForSelector:selector];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:methodSignature];
    [invocation setTarget:target];
    [invocation setSelector:selector];
    
    NSUInteger methodArgumentCount = [methodSignature numberOfArguments] - 2;
    if (methodArgumentCount != argumentCount) {
        NSString *reason = [NSString stringWithFormat:@"ObjC method %@ requires %lu %@, but JavaScript passed %zd %@", NSStringFromSelector(selector), (unsigned long)methodArgumentCount, (methodArgumentCount == 1 ? @"argument" : @"arguments"), argumentCount, (argumentCount == 1 ? @"argument" : @"arguments")];
        NSException *e = [NSException exceptionWithName:MORuntimeException reason:reason userInfo:nil];
        if (exception != NULL) {
            *exception = [runtime JSValueForObject:e];
        }
        return NULL;
    }
    
    // Build arguments
    for (size_t i=0; i<argumentCount; i++) {
        JSValueRef argument = arguments[i];
        __unsafe_unretained id object = [runtime objectForJSValue:argument];
        
        NSUInteger argIndex = i + 2;
        const char * argType = [methodSignature getArgumentTypeAtIndex:argIndex];
        
        // NSNumber
        if ([object isKindOfClass:[NSNumber class]]) {
            // long
            if (strcmp(argType, @encode(long)) == 0
                || strcmp(argType, @encode(unsigned long)) == 0) {
                long val = [object longValue];
                [invocation setArgument:&val atIndex:argIndex];
            }
            // short
            else if (strcmp(argType, @encode(short)) == 0
                     || strcmp(argType, @encode(unsigned short)) == 0) {
                short val = [object shortValue];
                [invocation setArgument:&val atIndex:argIndex];
                
            }
            // char
            else if (strcmp(argType, @encode(char)) == 0
                     || strcmp(argType, @encode(unsigned char)) == 0) {
                char val = [object charValue];
                [invocation setArgument:&val atIndex:argIndex];
            }
            // long long
            else if (strcmp(argType, @encode(long long)) == 0
                     || strcmp(argType, @encode(unsigned long long)) == 0) {
                long long val = [object longLongValue];
                [invocation setArgument:&val atIndex:argIndex];
            }
            // float
            else if (strcmp(argType, @encode(float)) == 0) {
                float val = [object floatValue];
                [invocation setArgument:&val atIndex:argIndex];
            }
            // double
            else if (strcmp(argType, @encode(double)) == 0) {
                double val = [object doubleValue];
                [invocation setArgument:&val atIndex:argIndex];
            }
            // BOOL
            else if (strcmp(argType, @encode(bool)) == 0
                     || strcmp(argType, @encode(_Bool)) == 0) {
                BOOL val = [object boolValue];
                [invocation setArgument:&val atIndex:argIndex];
            }
            // int
            else {
                int val = [object intValue];
                [invocation setArgument:&val atIndex:argIndex];
            }
        }
        // id
        else {
            [invocation setArgument:&object atIndex:argIndex];
        }
    }
    
    
    // Invoke
    [invocation invoke];
    
    
    // Build return value
    const char * returnType = [methodSignature methodReturnType];
    JSValueRef returnValue = NULL;
    
    if (strcmp(returnType, @encode(void)) == 0) {
        returnValue = JSValueMakeUndefined(ctx);
    }
    // id
    else if (strcmp(returnType, @encode(id)) == 0
             || strcmp(returnType, @encode(Class)) == 0) {
        __unsafe_unretained id object = nil;
        [invocation getReturnValue:&object];
        returnValue = [runtime JSValueForObject:object];
    }
    // SEL
    /*else if (strcmp(returnType, @encode(SEL)) == 0) {
        SEL selector = NULL;
        [invocation getReturnValue:&selector];
        
        returnValue = object;
    }*/
    // void *
    else if (strcmp(returnType, @encode(void *)) == 0) {
        void *pointer = NULL;
        [invocation getReturnValue:&pointer];
        
        MOPointerValue * __autoreleasing object = [[MOPointerValue alloc] initWithPointerValue:pointer typeEncoding:nil];
        returnValue = (__bridge void *)object;
    }
    // bool
    else if (strcmp(returnType, @encode(bool)) == 0
             || strcmp(returnType, @encode(_Bool)) == 0) {
        BOOL value;
        [invocation getReturnValue:&value];
        returnValue = [runtime JSValueForObject:[NSNumber numberWithBool:value]];
    }
    // int
    else if (strcmp(returnType, @encode(int)) == 0
             || strcmp(returnType, @encode(unsigned int)) == 0) {
        int value;
        [invocation getReturnValue:&value];
        returnValue = [runtime JSValueForObject:[NSNumber numberWithInt:value]];
    }
    // long
    else if (strcmp(returnType, @encode(long)) == 0
             || strcmp(returnType, @encode(unsigned long)) == 0) {
        long value;
        [invocation getReturnValue:&value];
        returnValue = [runtime JSValueForObject:[NSNumber numberWithLong:value]];
    }
    // long long
    else if (strcmp(returnType, @encode(long long)) == 0
             || strcmp(returnType, @encode(unsigned long long)) == 0) {
        long long value;
        [invocation getReturnValue:&value];
        returnValue = [runtime JSValueForObject:[NSNumber numberWithLongLong:value]];
    }
    // short
    else if (strcmp(returnType, @encode(short)) == 0
             || strcmp(returnType, @encode(unsigned short)) == 0) {
        short value;
        [invocation getReturnValue:&value];
        returnValue = [runtime JSValueForObject:[NSNumber numberWithShort:value]];
    }
    // char
    else if (strcmp(returnType, @encode(char)) == 0
             || strcmp(returnType, @encode(unsigned char)) == 0) {
        char value;
        [invocation getReturnValue:&value];
        returnValue = [runtime JSValueForObject:[NSNumber numberWithChar:value]];
    }
    // float
    else if (strcmp(returnType, @encode(float)) == 0) {
        float value;
        [invocation getReturnValue:&value];
        returnValue = [runtime JSValueForObject:[NSNumber numberWithFloat:value]];
    }
    // double
    else if (strcmp(returnType, @encode(double)) == 0) {
        double value;
        [invocation getReturnValue:&value];
        returnValue = [runtime JSValueForObject:[NSNumber numberWithDouble:value]];
    }
    
    return returnValue;
}

BOOL MOSelectorIsVariadic(Class klass, SEL selector) {
    NSString *className = [NSString stringWithUTF8String:class_getName(klass)];
    
    while (klass != Nil) {
        MOBridgeSupportClass *classSymbol = [[MOBridgeSupportController sharedController] symbolWithName:className type:[MOBridgeSupportClass class]];
        if (classSymbol == nil) {
            klass = [klass superclass];
            continue;
        }
        
        MOBridgeSupportMethod *methodSymbol = [classSymbol methodWithSelector:selector];
        if (methodSymbol != nil) {
            return [methodSymbol isVariadic];
        }
        
        klass = [klass superclass];
    }
    
    return NO;
}

MOFunctionArgument * MOFunctionArgumentForTypeEncoding(NSString *typeEncoding) {
    MOFunctionArgument *argument = [[MOFunctionArgument alloc] init];
    
    char typeEncodingChar = [typeEncoding UTF8String][0];
    
    if (typeEncodingChar == _C_STRUCT_B) {
        [argument setStructureTypeEncoding:typeEncoding];
    }
    else if (typeEncodingChar == _C_PTR) {
        if ([typeEncoding isEqualToString:@"^{__CFString=}"]) {
            [argument setTypeEncoding:_C_ID];
        }
        else {
            [argument setPointerTypeEncoding:typeEncoding];
        }
    }
    else {
        [argument setTypeEncoding:typeEncodingChar];
    }
    
    return argument;
}

NSArray * MOParseObjCMethodEncoding(const char *typeEncoding) {
    NSMutableArray *argumentEncodings = [NSMutableArray array];
    char *argsParser = (char *)typeEncoding;
    
    for(; *argsParser; argsParser++) {
        // Skip ObjC argument order
        if (*argsParser >= '0' && *argsParser <= '9') {
            continue;
        }
        else {
            // Skip ObjC type qualifiers - except for _C_CONST these are not defined in runtime.h
            if (*argsParser == _C_CONST ||
                *argsParser == 'n' ||
                *argsParser == 'N' || 
                *argsParser == 'o' ||
                *argsParser == 'O' ||
                *argsParser == 'R' ||
                *argsParser == 'V') {
                continue;
            }
            else {
                if (*argsParser == _C_STRUCT_B) {
                    // Parse structure encoding
                    NSInteger count = 0;
                    [MOFunctionArgument typeEncodingsFromStructureTypeEncoding:[NSString stringWithUTF8String:argsParser] parsedCount:&count];
                    
                    NSString *encoding = [[NSString alloc] initWithBytes:argsParser length:count encoding:NSUTF8StringEncoding];
                    MOFunctionArgument *argumentEncoding = [[MOFunctionArgument alloc] init];
                    
                    // Set return value
                    if ([argumentEncodings count] == 0) {
                        [argumentEncoding setReturnValue:YES];
                    }
                    
                    [argumentEncoding setStructureTypeEncoding:encoding];
                    [argumentEncodings addObject:argumentEncoding];
                    
                    argsParser += count - 1;
                }
                else {
                    // Custom handling for pointers as they're not one char long.
                    char* typeStart = argsParser;
                    if (*argsParser == '^') {
                        while (*argsParser && !(*argsParser >= '0' && *argsParser <= '9')) {
                            argsParser++;
                        }
                    }
                    
                    MOFunctionArgument *argumentEncoding = [[MOFunctionArgument alloc] init];
                    
                    // Set return value
                    if ([argumentEncodings count] == 0) {
                        [argumentEncoding setReturnValue:YES];
                    }
                    
                    // If pointer, copy pointer type (^i, ^{NSRect}) to the argumentEncoding
                    if (*typeStart == _C_PTR) {
                        NSString *encoding = [[NSString alloc] initWithBytes:typeStart length:(argsParser - typeStart) encoding:NSUTF8StringEncoding];
                        [argumentEncoding setPointerTypeEncoding:encoding];
                    }
                    else {
                        @try {
                            [argumentEncoding setTypeEncoding:*typeStart];
                        }
                        @catch (NSException *e) {
                            return nil;
                        }
                        
                        // Blocks are '@?', skip '?'
                        if (typeStart[0] == _C_ID && typeStart[1] == _C_UNDEF) {
                            argsParser++;
                        }
                    }
                    
                    [argumentEncodings addObject:argumentEncoding];
                }
            }
        }
        
        if (!*argsParser) {
            break;
        }
    }
    return argumentEncodings;
}


//
// From PyObjC : when to call objc_msgSend_stret, for structure return
// Depending on structure size & architecture, structures are returned as function first argument (done transparently by ffi) or via registers
//

#if defined(__ppc__)
#   define SMALL_STRUCT_LIMIT    4
#elif defined(__ppc64__)
#   define SMALL_STRUCT_LIMIT    8
#elif defined(__i386__) 
#   define SMALL_STRUCT_LIMIT     8
#elif defined(__x86_64__) 
#   define SMALL_STRUCT_LIMIT    16
#elif TARGET_OS_IPHONE
// TOCHECK
#   define SMALL_STRUCT_LIMIT    4
#else
#   error "Unsupported MACOSX platform"
#endif

BOOL MOInvocationShouldUseStret(NSArray *arguments) {
    size_t resultSize = 0;
    char returnEncoding = [(MOFunctionArgument *)[arguments objectAtIndex:0] typeEncoding];
    if (returnEncoding == _C_STRUCT_B) {
        resultSize = [MOFunctionArgument sizeOfStructureTypeEncoding:[[arguments objectAtIndex:0] structureTypeEncoding]];
    }
    
    if (returnEncoding == _C_STRUCT_B && 
        //#ifdef  __ppc64__
        //            ffi64_stret_needs_ptr(signature_to_ffi_return_type(rettype), NULL, NULL)
        //
        //#else /* !__ppc64__ */
        (resultSize > SMALL_STRUCT_LIMIT
#ifdef __i386__
         /* darwin/x86 ABI is slightly odd ;-) */
         || (resultSize != 1 
             && resultSize != 2 
             && resultSize != 4 
             && resultSize != 8)
#endif
#ifdef __x86_64__
         /* darwin/x86-64 ABI is slightly odd ;-) */
         || (resultSize != 1 
             && resultSize != 2 
             && resultSize != 4 
             && resultSize != 8
             && resultSize != 16
             )
#endif
         )
        //#endif /* !__ppc64__ */
        ) {
        //                    callAddress = objc_msgSend_stret;
        //                    usingStret = YES;
        return YES;
    }
    return NO;
}

void * MOInvocationGetObjCCallAddressForArguments(NSArray *arguments) {
    BOOL usingStret = MOInvocationShouldUseStret(arguments);
    void *callAddress = NULL;
    if (usingStret)    {
        callAddress = objc_msgSend_stret;
    }
    else {
        callAddress = objc_msgSend;
    }
    
#if __i386__
    // If i386 and the return type is float/double, use objc_msgSend_fpret
    // ARM and x86_64 use the standard objc_msgSend
    char returnEncoding = [[arguments objectAtIndex:0] typeEncoding];
    if (returnEncoding == 'f' || returnEncoding == 'd') {
        callAddress = objc_msgSend_fpret;
    }
#endif
    
    return callAddress;
}


#pragma mark -
#pragma mark Selectors

SEL MOSelectorFromPropertyName(NSString *propertyName) {
    NSString *selectorString = [propertyName stringByReplacingOccurrencesOfString:@"_" withString:@":"];
    SEL selector = NSSelectorFromString(selectorString);
    return selector;
}

NSString * MOSelectorToPropertyName(SEL selector) {
    NSString *selectorString = NSStringFromSelector(selector);
    NSString *propertyString = [selectorString stringByReplacingOccurrencesOfString:@":" withString:@"_"];
    return propertyString;
}

NSString * MOPropertyNameToSetterName(NSString *propertyName) {
    if ([propertyName length] > 0) {
        // Capitalize first character and append "set" and "_"
        // title -> setTitle_
        NSString *capitalizedName = [NSString stringWithFormat:@"%@%@", [[propertyName substringToIndex:1] capitalizedString], [propertyName substringFromIndex:1]];
        return [[@"set" stringByAppendingString:capitalizedName] stringByAppendingString:@"_"];
    }
    else {
        return nil;
    }
}


#pragma mark -
#pragma mark Blocks

//typedef id (^MOJavaScriptClosureBlock)(id obj, ...);
//
//id MOGetBlockForJavaScriptFunction(MOJavaScriptFunction *function, NSUInteger *argCount) {
//    JSObjectRef jsFunction = [function JSObject];
//    JSContextRef ctx = [function JSContext];
//    
//    if (argCount != NULL) {
//        JSStringRef lengthString = JSStringCreateWithCFString(CFSTR("length"));
//        JSValueRef value = JSObjectGetProperty(ctx, jsFunction, lengthString, NULL);
//        JSStringRelease(lengthString);
//        
//        *argCount = (NSUInteger)JSValueToNumber(ctx, value, NULL);
//    }
//    
//    MOJavaScriptClosureBlock newBlock = (id)^(id obj, ...) {
//        // JavaScript functions
//        JSObjectRef jsFunction = [function JSObject];
//        JSContextRef ctx = [function JSContext];
//        MORuntime *runtime = [MORuntime runtimeWithContext:ctx];
//        
//        JSStringRef lengthString = JSStringCreateWithCFString(CFSTR("length"));
//        JSValueRef value = JSObjectGetProperty(ctx, jsFunction, lengthString, NULL);
//        JSStringRelease(lengthString);
//        
//        NSUInteger argCount = (NSUInteger)JSValueToNumber(ctx, value, NULL);
//        
//        JSValueRef exception = NULL;
//        
//        va_list args;
//        va_start(args, obj);
//        
//        id arg = obj;
//        JSValueRef jsValue = [runtime JSValueForObject:obj];
//        JSObjectRef jsObject = JSValueToObject(ctx, jsValue, &exception);
//        if (jsObject == NULL) {
//            [runtime throwJSException:exception];
//            return nil;
//        }
//        
//        JSValueRef *jsArguments = (JSValueRef *)malloc(sizeof(JSValueRef) * (argCount - 1));
//        
//        // Handle passed arguments
//        for (NSUInteger i=0; i<argCount; i++) {
//            arg = va_arg(args, id);
//            jsArguments[i] = [runtime JSValueForObject:arg];
//        }
//        
//        va_end(args);
//        
//        JSValueRef jsReturnValue = JSObjectCallAsFunction(ctx, jsFunction, jsObject, argCount, jsArguments, &exception);
//        id returnValue = [runtime objectForJSValue:jsReturnValue];
//        
//        if (jsArguments != NULL) {
//            free(jsArguments);
//        }
//        
//        if (exception != NULL) {
//            [runtime throwJSException:exception];
//            return nil;
//        }
//        
//        return (__bridge void*)returnValue;
//    };
//    return [newBlock copy];
//}

//
// The following two structs are taken from clang's source.
//

struct Block_descriptor {
    unsigned long reserved;
    unsigned long size;
    void *rest[1];
};

struct Block_literal {
    void *isa;
    int flags;
    int reserved;
    void *invoke;
    struct Block_descriptor *descriptor;
};

void * MOBlockGetCallAddress(id blockObj, const char ** typeEncoding) {
    struct Block_literal *block = (__bridge struct Block_literal *)blockObj;
    if (typeEncoding != nil) {
        struct Block_descriptor *descriptor = block->descriptor;
        
        int copyDisposeFlag = 1 << 25;
        int signatureFlag = 1 << 30;
        
        assert(block->flags & signatureFlag);
        
        int index = 0;
        if (block->flags & copyDisposeFlag) {
            index += 2;
        }
        
        *typeEncoding = descriptor->rest[index];
    }
    return block->invoke;
}
