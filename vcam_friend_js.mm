// VCAM_FRIEND_JS_* 桩实现 —— 原文件缺失时的替代
// 用途：让链接器找到符号，避免 Undefined symbols 错误
// 运行时：WebCam JS 模式（Safari）会返回空桩，其他模式不受影响
//
// 如后续找到原作者真正的 vcam_friend_js.mm，直接替换此文件即可。
// 真正的实现应该是：把混淆加密的 JS 源码解密后返回。

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

NSString *VCAM_FRIEND_JS_STREAM_GET(void) { return @"/*stream-stub*/"; }
NSString *VCAM_FRIEND_JS_VIDEO_GET(void)  { return @"/*video-stub*/"; }
NSString *VCAM_FRIEND_JS_IMAGE_GET(void)  { return @"/*image-stub*/"; }

#ifdef __cplusplus
}
#endif
