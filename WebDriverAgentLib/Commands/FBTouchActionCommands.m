/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBTouchActionCommands.h"

#import "FBRoute.h"
#import "FBRouteRequest.h"
#import "FBSession.h"
#import "XCUIApplication+FBTouchAction.h"
#if !TARGET_OS_TV && !TARGET_OS_WATCH
#import "FBBaseActionsSynthesizer.h"
#import "FBCommandStatus.h"
#import "FBConfiguration.h"
#import "FBErrorBuilder.h"
#import "FBXCTestDaemonsProxy.h"
#import "XCPointerEventPath.h"
#import "XCSynthesizedEventRecord.h"
#import "XCUIApplication+FBHelpers.h"
#import "XCUIDevice.h"
#import "XCUIElement+FBUtilities.h"
#endif

@implementation FBTouchActionCommands

#pragma mark - <FBCommandHandler>

+ (NSArray *)routes
{
  return
  @[
    [[FBRoute POST:@"/actions"] respondWithTarget:self action:@selector(handlePerformW3CTouchActions:)],
#if !TARGET_OS_TV && !TARGET_OS_WATCH
    // /wda/absolute-actions: touch gestures at absolute viewport coordinates,
    // without resolving the active application. Works with or without a session.
    [[FBRoute POST:@"/wda/absolute-actions"].withoutSession respondWithTarget:self action:@selector(handleAbsoluteTouchActions:)],
    [[FBRoute POST:@"/wda/absolute-actions"] respondWithTarget:self action:@selector(handleAbsoluteTouchActions:)],
#endif
  ];
}

#pragma mark - Commands

+ (id<FBResponsePayload>)handlePerformW3CTouchActions:(FBRouteRequest *)request
{
  XCUIApplication *application = request.session.activeApplication;
  NSArray *actions = (NSArray *)request.arguments[@"actions"];
  NSError *error;
  if (![application fb_performW3CActions:actions elementCache:request.session.elementCache error:&error]) {
    return FBResponseWithUnknownError(error);
  }
  return FBResponseWithOK();
}

#if !TARGET_OS_TV && !TARGET_OS_WATCH

#pragma mark - Absolute touch actions

/**
 POST /wda/absolute-actions

 Performs touch gestures at absolute viewport coordinates without resolving the
 active application, so it works without a live session and does not wait for
 the application's accessibility state.

 Supported input is a strict subset of the W3C actions format and anything
 outside of it is rejected with an invalid argument error:
 - sources of type "pointer" with pointerType "touch" (or omitted)
 - items: pointerMove (origin omitted or "viewport", numeric x/y >= 0),
   pointerDown / pointerUp (button 0 or omitted), pause
 - optional non-negative numeric "duration" in milliseconds
 Each pointerDown ... pointerUp pair is one touch path; every source starts at
 offset 0, so several sources produce a multi-touch gesture.

 Optional request argument "waitForStable" (boolean, default false): wait for the
 active application to become stable after the gesture (this does look up the
 active application).
 */

static const NSTimeInterval FBAbsoluteActionMaxDurationMs = 600000;

static UIInterfaceOrientation FBAbsoluteActionsInterfaceOrientation(void)
{
  // The device orientation is mirrored (landscape left <-> landscape right)
  // when expressed as an interface orientation.
  switch ([XCUIDevice sharedDevice].orientation) {
    case UIDeviceOrientationPortraitUpsideDown:
      return UIInterfaceOrientationPortraitUpsideDown;
    case UIDeviceOrientationLandscapeLeft:
      return UIInterfaceOrientationLandscapeRight;
    case UIDeviceOrientationLandscapeRight:
      return UIInterfaceOrientationLandscapeLeft;
    case UIDeviceOrientationPortrait:
    default:
      return UIInterfaceOrientationPortrait;
  }
}

static BOOL FBAbsoluteActionsFail(NSError **error, NSString *description)
{
  if (error) {
    *error = [[FBErrorBuilder.builder withDescription:description] build];
  }
  return NO;
}

static BOOL FBAbsoluteActionsNumber(id value, NSString *name, double max, double *result, NSError **error)
{
  if (![value isKindOfClass:NSNumber.class] || [value isKindOfClass:NSClassFromString(@"__NSCFBoolean")]) {
    return FBAbsoluteActionsFail(error, [NSString stringWithFormat:@"'%@' must be a number", name]);
  }
  double number = [value doubleValue];
  if (!isfinite(number) || number < 0 || number > max) {
    return FBAbsoluteActionsFail(error, [NSString stringWithFormat:@"'%@' must be between 0 and %.0f", name, max]);
  }
  *result = number;
  return YES;
}

static BOOL FBAbsoluteActionsDuration(NSDictionary *item, NSTimeInterval *seconds, NSError **error)
{
  id value = item[@"duration"];
  if (nil == value) {
    *seconds = 0;
    return YES;
  }
  double ms = 0;
  if (!FBAbsoluteActionsNumber(value, @"duration", FBAbsoluteActionMaxDurationMs, &ms, error)) {
    return NO;
  }
  *seconds = ms / 1000.0;
  return YES;
}

static BOOL FBAbsoluteActionsButtonIsValid(NSDictionary *item)
{
  id button = item[@"button"];
  return nil == button || ([button isKindOfClass:NSNumber.class] && [button integerValue] == 0);
}

static XCSynthesizedEventRecord *FBAbsoluteActionsRecord(id actions, NSError **error)
{
  if (![actions isKindOfClass:NSArray.class] || [(NSArray *)actions count] == 0) {
    FBAbsoluteActionsFail(error, @"'actions' must be a non-empty array");
    return nil;
  }
  XCSynthesizedEventRecord *record = [[XCSynthesizedEventRecord alloc] initWithName:@"WDA absolute touch"
                                                               interfaceOrientation:FBAbsoluteActionsInterfaceOrientation()];
  NSUInteger pathsCount = 0;
  for (id source in (NSArray *)actions) {
    if (![source isKindOfClass:NSDictionary.class]) {
      FBAbsoluteActionsFail(error, @"Each action source must be an object");
      return nil;
    }
    if (![@"pointer" isEqual:source[@"type"]]) {
      FBAbsoluteActionsFail(error, @"Only 'pointer' action sources are supported");
      return nil;
    }
    id pointerType = [source[@"parameters"] isKindOfClass:NSDictionary.class] ? source[@"parameters"][@"pointerType"] : nil;
    if (nil != pointerType && ![@"touch" isEqual:pointerType]) {
      FBAbsoluteActionsFail(error, @"Only the 'touch' pointer type is supported");
      return nil;
    }
    NSArray *items = source[@"actions"];
    if (![items isKindOfClass:NSArray.class]) {
      FBAbsoluteActionsFail(error, @"'actions' of a pointer source must be an array");
      return nil;
    }

    CGPoint point = CGPointZero;
    BOOL hasPoint = NO;
    NSTimeInterval offset = 0;
    XCPointerEventPath *path = nil;
    for (id rawItem in items) {
      if (![rawItem isKindOfClass:NSDictionary.class]) {
        FBAbsoluteActionsFail(error, @"Each pointer action must be an object");
        return nil;
      }
      NSDictionary *item = rawItem;
      NSString *type = item[@"type"];
      NSTimeInterval duration = 0;
      if (![type isKindOfClass:NSString.class]) {
        FBAbsoluteActionsFail(error, @"Each pointer action must have a 'type'");
        return nil;
      }
      if ([type isEqualToString:@"pointerMove"]) {
        id origin = item[@"origin"];
        if (nil != origin && ![@"viewport" isEqual:origin]) {
          FBAbsoluteActionsFail(error, @"Only the 'viewport' origin is supported");
          return nil;
        }
        double x = 0, y = 0;
        if (!FBAbsoluteActionsNumber(item[@"x"], @"x", CGFLOAT_MAX, &x, error)
            || !FBAbsoluteActionsNumber(item[@"y"], @"y", CGFLOAT_MAX, &y, error)
            || !FBAbsoluteActionsDuration(item, &duration, error)) {
          return nil;
        }
        point = CGPointMake(x, y);
        hasPoint = YES;
        offset += duration;
        if (nil != path) {
          [path moveToPoint:point atOffset:offset];
        }
      } else if ([type isEqualToString:@"pointerDown"]) {
        if (!FBAbsoluteActionsButtonIsValid(item)) {
          FBAbsoluteActionsFail(error, @"Only button 0 is supported");
          return nil;
        }
        if (nil != path) {
          FBAbsoluteActionsFail(error, @"'pointerDown' while the pointer is already down");
          return nil;
        }
        if (!hasPoint) {
          FBAbsoluteActionsFail(error, @"'pointerDown' requires a preceding 'pointerMove'");
          return nil;
        }
        // The touch-down event is emitted by the path initializer itself.
        path = [[XCPointerEventPath alloc] initForTouchAtPoint:point offset:offset];
      } else if ([type isEqualToString:@"pointerUp"]) {
        if (!FBAbsoluteActionsButtonIsValid(item)) {
          FBAbsoluteActionsFail(error, @"Only button 0 is supported");
          return nil;
        }
        if (nil == path) {
          FBAbsoluteActionsFail(error, @"'pointerUp' without a preceding 'pointerDown'");
          return nil;
        }
        [path liftUpAtOffset:offset];
        [record addPointerEventPath:path];
        pathsCount++;
        path = nil;
      } else if ([type isEqualToString:@"pause"]) {
        if (!FBAbsoluteActionsDuration(item, &duration, error)) {
          return nil;
        }
        offset += duration;
      } else {
        FBAbsoluteActionsFail(error, [NSString stringWithFormat:@"Unsupported pointer action type '%@'", type]);
        return nil;
      }
    }
    if (nil != path) {
      FBAbsoluteActionsFail(error, @"Every 'pointerDown' must be followed by a 'pointerUp'");
      return nil;
    }
  }
  if (0 == pathsCount) {
    FBAbsoluteActionsFail(error, @"The actions do not contain any touch gesture");
    return nil;
  }
  return record;
}

+ (id<FBResponsePayload>)handleAbsoluteTouchActions:(FBRouteRequest *)request
{
  NSError *error;
  XCSynthesizedEventRecord *record = FBAbsoluteActionsRecord(request.arguments[@"actions"], &error);
  if (nil == record) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:error.localizedDescription traceback:nil]);
  }
  if (![FBXCTestDaemonsProxy synthesizeEventWithRecord:record error:&error]) {
    return FBResponseWithUnknownError(error);
  }
  id waitForStable = request.arguments[@"waitForStable"];
  if ([waitForStable isKindOfClass:NSNumber.class] && [waitForStable boolValue]) {
    [XCUIApplication.fb_activeApplication fb_waitUntilStableWithTimeout:FBConfiguration.sharedInstance.animationCoolOffTimeout];
  }
  return FBResponseWithOK();
}

#endif

@end
