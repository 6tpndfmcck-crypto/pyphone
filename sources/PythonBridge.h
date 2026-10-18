#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PythonBridge : NSObject
/// Starts the interpreter. Returns nil on success, or an error message.
+ (nullable NSString *)start;
/// Calls runner.<function>(arg) and returns its string result.
+ (NSString *)call:(NSString *)function arg:(NSString *)arg;
/// Raises KeyboardInterrupt in the given Python thread.
+ (void)stopThread:(unsigned long)ident;
@end

NS_ASSUME_NONNULL_END
