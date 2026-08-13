// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit/browser/orbit_video_overlay_window_mac.h"

#import <Cocoa/Cocoa.h>

#include <algorithm>
#include <cmath>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "base/apple/scoped_cftyperef.h"
#include "base/functional/bind.h"
#include "base/location.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "cc/layers/deadline_policy.h"
#include "components/viz/common/surfaces/surface_id.h"
#include "content/public/browser/context_factory.h"
#include "content/public/browser/immersive_playback_options.h"
#include "content/public/browser/overlay_window.h"
#include "content/public/browser/video_picture_in_picture_window_controller.h"
#include "services/media_session/public/cpp/media_image.h"
#include "services/media_session/public/cpp/media_image_manager.h"
#include "services/media_session/public/cpp/media_position.h"
#include "third_party/skia/include/core/SkBitmap.h"
#include "third_party/skia/include/core/SkColor.h"
#include "third_party/skia/include/utils/mac/SkCGUtils.h"
#include "ui/accelerated_widget_mac/accelerated_widget_mac.h"
#include "ui/accelerated_widget_mac/display_ca_layer_tree.h"
#include "ui/compositor/layer.h"
#include "ui/compositor/recyclable_compositor_mac.h"
#include "ui/display/display.h"
#include "ui/display/screen.h"
#include "ui/gfx/ca_layer_params.h"
#include "ui/gfx/geometry/dip_util.h"
#include "ui/gfx/geometry/size_conversions.h"
#include "ui/gfx/mac/coordinate_conversion.h"

namespace orbit {
class OrbitVideoOverlayWindowMac;
}  // namespace orbit

namespace {

// Every control content::VideoOverlayWindow exposes a visibility setter for,
// plus the two pieces of window chrome it leaves to the embedder.
enum PiPControl : NSInteger {
  kControlClose = 1,
  kControlBackToTab,
  kControlPlayPause,
  kControlPreviousTrack,
  kControlNextTrack,
  kControlSkipAd,
  kControlToggleMute,
  kControlToggleMicrophone,
  kControlToggleCamera,
  kControlHangUp,
  kControlPreviousSlide,
  kControlNextSlide,
};

constexpr CGFloat kControlSize = 30;
constexpr CGFloat kPrimaryControlSize = 44;
constexpr CGFloat kEdgeInset = 8;
constexpr CGFloat kProgressHeight = 3;
constexpr CGFloat kTitleHeight = 18;
constexpr int kMinContentWidth = 284;
constexpr int kMinContentHeight = 160;

NSImage* SymbolImage(NSString* name, CGFloat point_size) {
  NSImage* image = [NSImage imageWithSystemSymbolName:name
                             accessibilityDescription:name];
  NSImageSymbolConfiguration* configuration =
      [NSImageSymbolConfiguration configurationWithPointSize:point_size
                                                      weight:NSFontWeightMedium
                                                       scale:NSImageSymbolScaleMedium];
  return [image imageWithSymbolConfiguration:configuration];
}

NSImage* ImageFromSkBitmap(const SkBitmap& bitmap) {
  if (bitmap.drawsNothing()) {
    return nil;
  }
  base::apple::ScopedCFTypeRef<CGImageRef> cg_image(SkCreateCGImageRef(bitmap));
  if (!cg_image) {
    return nil;
  }
  return [[NSImage alloc] initWithCGImage:cg_image.get()
                                     size:NSMakeSize(bitmap.width(),
                                                     bitmap.height())];
}

}  // namespace

// Weak back-reference holder: AppKit can outlive the C++ owner by a turn of
// the run loop, so every ObjC->C++ hop goes through this and no-ops once the
// owner is cleared.
@interface OrbitPiPBridge : NSObject <NSWindowDelegate>
@property(nonatomic, assign) orbit::OrbitVideoOverlayWindowMac* owner;
- (void)controlClicked:(NSButton*)sender;
- (void)seekToFraction:(double)fraction;
- (void)hoverChanged:(BOOL)hovering;
- (void)progressTick;
@end

@interface OrbitPiPPanel : NSPanel
@end

@implementation OrbitPiPPanel
- (BOOL)canBecomeKeyWindow {
  return YES;
}
- (BOOL)canBecomeMainWindow {
  return NO;
}
@end

@interface OrbitPiPProgressView : NSView
@property(nonatomic, assign) double fraction;
@property(nonatomic, weak) OrbitPiPBridge* bridge;
@end

@implementation OrbitPiPProgressView
@synthesize fraction = _fraction;
@synthesize bridge = _bridge;
- (void)drawRect:(NSRect)dirtyRect {
  [[NSColor colorWithWhite:1.0 alpha:0.25] setFill];
  NSRectFillUsingOperation(self.bounds, NSCompositingOperationSourceOver);
  NSRect filled = self.bounds;
  filled.size.width *= std::clamp(_fraction, 0.0, 1.0);
  [[NSColor colorWithWhite:1.0 alpha:0.9] setFill];
  NSRectFillUsingOperation(filled, NSCompositingOperationSourceOver);
}
- (void)mouseDown:(NSEvent*)event {
  if (NSWidth(self.bounds) <= 0) {
    return;
  }
  NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
  [_bridge seekToFraction:point.x / NSWidth(self.bounds)];
}
@end

// The hover overlay: scrim, title row, progress bar and every button. Laid
// out by hand because which controls exist changes at runtime.
@interface OrbitPiPControlsView : NSView {
  NSMutableDictionary<NSNumber*, NSButton*>* _buttons;
  NSTrackingArea* _trackingArea;
}
@property(nonatomic, weak) OrbitPiPBridge* bridge;
@property(nonatomic, strong) NSTextField* titleField;
@property(nonatomic, strong) NSImageView* faviconView;
@property(nonatomic, strong) OrbitPiPProgressView* progressView;
- (NSButton*)buttonForControl:(NSInteger)control;
- (void)addControl:(NSInteger)control symbol:(NSString*)symbol primary:(BOOL)primary;
@end

@implementation OrbitPiPControlsView
@synthesize bridge = _bridge;
@synthesize titleField = _titleField;
@synthesize faviconView = _faviconView;
@synthesize progressView = _progressView;

- (instancetype)initWithFrame:(NSRect)frame {
  if (self = [super initWithFrame:frame]) {
    _buttons = [NSMutableDictionary dictionary];
    self.wantsLayer = YES;
    self.layer.backgroundColor = [NSColor colorWithWhite:0 alpha:0.32].CGColor;

    _faviconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _faviconView.imageScaling = NSImageScaleProportionallyUpOrDown;
    [self addSubview:_faviconView];

    _titleField = [NSTextField labelWithString:@""];
    _titleField.textColor = [NSColor whiteColor];
    _titleField.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    _titleField.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:_titleField];

    _progressView = [[OrbitPiPProgressView alloc] initWithFrame:NSZeroRect];
    [self addSubview:_progressView];
  }
  return self;
}

- (void)addControl:(NSInteger)control symbol:(NSString*)symbol primary:(BOOL)primary {
  const CGFloat size = primary ? kPrimaryControlSize : kControlSize;
  NSButton* button = [NSButton buttonWithImage:SymbolImage(symbol, primary ? 19 : 12)
                                        target:nil
                                        action:@selector(controlClicked:)];
  button.bordered = NO;
  button.imagePosition = NSImageOnly;
  button.contentTintColor = [NSColor whiteColor];
  button.tag = control;
  button.hidden = YES;
  button.wantsLayer = YES;
  button.layer.backgroundColor = [NSColor colorWithWhite:0 alpha:0.45].CGColor;
  button.layer.cornerRadius = size / 2;
  [self addSubview:button];
  _buttons[@(control)] = button;
}

- (NSButton*)buttonForControl:(NSInteger)control {
  return _buttons[@(control)];
}

- (void)setBridge:(OrbitPiPBridge*)bridge {
  _bridge = bridge;
  _progressView.bridge = bridge;
  for (NSButton* button in _buttons.allValues) {
    button.target = bridge;
  }
}

- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (_trackingArea) {
    [self removeTrackingArea:_trackingArea];
  }
  _trackingArea = [[NSTrackingArea alloc]
      initWithRect:self.bounds
           options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways |
                   NSTrackingInVisibleRect
             owner:self
          userInfo:nil];
  [self addTrackingArea:_trackingArea];
}

- (void)setFrameSize:(NSSize)newSize {
  [super setFrameSize:newSize];
  self.needsLayout = YES;
}

- (void)mouseEntered:(NSEvent*)event {
  [_bridge hoverChanged:YES];
}

- (void)mouseExited:(NSEvent*)event {
  [_bridge hoverChanged:NO];
}

- (void)layout {
  [super layout];
  const NSRect bounds = self.bounds;

  _progressView.frame = NSMakeRect(0, 0, NSWidth(bounds), kProgressHeight);
  [_progressView setNeedsDisplay:YES];

  const CGFloat top = NSHeight(bounds) - kEdgeInset - kControlSize;
  [self buttonForControl:kControlClose].frame =
      NSMakeRect(kEdgeInset, top, kControlSize, kControlSize);
  [self buttonForControl:kControlBackToTab].frame =
      NSMakeRect(NSWidth(bounds) - kEdgeInset - kControlSize, top, kControlSize,
                 kControlSize);

  const CGFloat titleLeft = kEdgeInset + kControlSize + kEdgeInset;
  const CGFloat titleWidth = std::max<CGFloat>(0, NSWidth(bounds) - 2 * titleLeft);
  const CGFloat titleY = top + (kControlSize - kTitleHeight) / 2;
  _faviconView.frame = NSMakeRect(titleLeft, titleY, kTitleHeight, kTitleHeight);
  _titleField.frame =
      NSMakeRect(titleLeft + kTitleHeight + 4, titleY,
                 std::max<CGFloat>(0, titleWidth - kTitleHeight - 4), kTitleHeight);

  NSArray<NSNumber*>* centreOrder =
      @[ @(kControlPreviousTrack), @(kControlPlayPause), @(kControlNextTrack) ];
  CGFloat centreWidth = 0;
  for (NSNumber* key in centreOrder) {
    if (_buttons[key].hidden) {
      continue;
    }
    centreWidth +=
        (key.integerValue == kControlPlayPause ? kPrimaryControlSize : kControlSize) +
        kEdgeInset;
  }
  centreWidth = std::max<CGFloat>(0, centreWidth - kEdgeInset);
  CGFloat x = (NSWidth(bounds) - centreWidth) / 2;
  for (NSNumber* key in centreOrder) {
    NSButton* button = _buttons[key];
    if (button.hidden) {
      continue;
    }
    const CGFloat size =
        key.integerValue == kControlPlayPause ? kPrimaryControlSize : kControlSize;
    button.frame = NSMakeRect(x, (NSHeight(bounds) - size) / 2, size, size);
    x += size + kEdgeInset;
  }

  NSArray<NSNumber*>* bottomOrder = @[
    @(kControlToggleMute), @(kControlSkipAd), @(kControlToggleMicrophone),
    @(kControlToggleCamera), @(kControlHangUp), @(kControlPreviousSlide),
    @(kControlNextSlide)
  ];
  CGFloat bx = kEdgeInset;
  const CGFloat bottomY = kProgressHeight + kEdgeInset;
  for (NSNumber* key in bottomOrder) {
    NSButton* button = _buttons[key];
    if (button.hidden) {
      continue;
    }
    button.frame = NSMakeRect(bx, bottomY, kControlSize, kControlSize);
    bx += kControlSize + kEdgeInset;
  }
}

@end

namespace orbit {

class OrbitVideoOverlayWindowMac : public content::VideoOverlayWindow,
                                   public ui::AcceleratedWidgetMacNSView {
 public:
  explicit OrbitVideoOverlayWindowMac(
      content::VideoPictureInPictureWindowController* controller);
  OrbitVideoOverlayWindowMac(const OrbitVideoOverlayWindowMac&) = delete;
  OrbitVideoOverlayWindowMac& operator=(const OrbitVideoOverlayWindowMac&) = delete;
  ~OrbitVideoOverlayWindowMac() override;

  // content::VideoOverlayWindow:
  bool IsActive() const override;
  void Close() override;
  void ShowInactive() override;
  void Hide() override;
  bool IsVisible() const override;
  gfx::Rect GetBounds() override;
  void UpdateNaturalSize(const gfx::Size& natural_size) override;
  void SetPlaybackState(PlaybackState playback_state) override;
  void SetPlayPauseButtonVisibility(bool is_visible) override;
  void SetSkipAdButtonVisibility(bool is_visible) override;
  void SetNextTrackButtonVisibility(bool is_visible) override;
  void SetPreviousTrackButtonVisibility(bool is_visible) override;
  void SetHidePictureInPictureButtonVisibility(bool is_visible) override;
  void SetMicrophoneMuted(bool muted) override;
  void SetCameraState(bool turned_on) override;
  void SetMediaMuted(bool muted) override;
  void SetToggleMicrophoneButtonVisibility(bool is_visible) override;
  void SetToggleCameraButtonVisibility(bool is_visible) override;
  void SetHangUpButtonVisibility(bool is_visible) override;
  void SetNextSlideButtonVisibility(bool is_visible) override;
  void SetPreviousSlideButtonVisibility(bool is_visible) override;
  void SetMediaPosition(const media_session::MediaPosition& position) override;
  void SetSourceTitle(const std::u16string& source_title) override;
  void SetFaviconImages(
      const std::vector<media_session::MediaImage>& images) override;
  void SetSurfaceId(const viz::SurfaceId& surface_id) override;
  void SetPlaybackControlsVisibility(bool is_visible) override;
  void SetImmersiveVideoOptions(const content::ImmersiveOptions&) override;

  // ui::AcceleratedWidgetMacNSView:
  void AcceleratedWidgetCALayerParamsUpdated(
      gfx::CALayerParams ca_layer_params) override;

  // Reached only from OrbitPiPBridge.
  void OnControlActivated(NSInteger control);
  void OnSeekToFraction(double fraction);
  void OnHoverChanged(bool hovering);
  void OnProgressTick();
  void OnWindowResized();
  void OnWindowWillClose();

 private:
  struct Native;

  void BuildWindow();
  void TearDownCompositor();
  void DestroyWindow();
  void NotifyControllerWindowDestroyed(bool should_pause_video);
  void ApplyContentSize(const gfx::Size& size_in_dip);
  void UpdateCompositorSurface();
  void PushSurfaceToLayer();
  void MaybeUnregisterFrameSinkHierarchy();
  void SetControlVisible(NSInteger control, bool is_visible);
  void UpdateSymbols();
  void RefreshProgress();
  void StartProgressTimerIfNeeded();
  void StopProgressTimer();
  void OnFaviconBitmap(const SkBitmap& bitmap);
  display::Display CurrentDisplay() const;
  gfx::Size FitToAspectRatio(const gfx::Size& desired) const;

  raw_ptr<content::VideoPictureInPictureWindowController> controller_;

  std::unique_ptr<Native> native_;
  std::unique_ptr<ui::RecyclableCompositorMac> compositor_;
  std::unique_ptr<ui::DisplayCALayerTree> display_ca_layer_tree_;
  std::unique_ptr<ui::LayerSolidColor> root_layer_;
  std::unique_ptr<ui::Layer> video_layer_;

  gfx::Size natural_size_;
  viz::SurfaceId surface_id_;
  bool has_registered_frame_sink_hierarchy_ = false;
  bool has_been_shown_ = false;
  bool is_torn_down_ = false;
  bool notified_destroyed_ = false;
  bool show_play_pause_button_ = false;
  bool playback_controls_visible_ = true;
  bool media_muted_ = false;
  bool microphone_muted_ = false;
  bool camera_on_ = false;
  PlaybackState playback_state_ = kPaused;
  std::optional<media_session::MediaPosition> media_position_;

  // Which controls content asked for, independent of whether the whole
  // playback-control set is currently suppressed.
  std::map<NSInteger, bool> requested_visibility_;

  base::WeakPtrFactory<OrbitVideoOverlayWindowMac> weak_factory_{this};
};

struct OrbitVideoOverlayWindowMac::Native {
  OrbitPiPPanel* __strong panel = nil;
  NSView* __strong surface_view = nil;
  OrbitPiPControlsView* __strong controls = nil;
  OrbitPiPBridge* __strong bridge = nil;
  NSTimer* __strong progress_timer = nil;
};

std::unique_ptr<content::VideoOverlayWindow> CreateVideoOverlayWindowMac(
    content::VideoPictureInPictureWindowController* controller) {
  return std::make_unique<OrbitVideoOverlayWindowMac>(controller);
}

OrbitVideoOverlayWindowMac::OrbitVideoOverlayWindowMac(
    content::VideoPictureInPictureWindowController* controller)
    : controller_(controller), native_(std::make_unique<Native>()) {
  BuildWindow();
}

OrbitVideoOverlayWindowMac::~OrbitVideoOverlayWindowMac() {
  StopProgressTimer();
  TearDownCompositor();
  DestroyWindow();
}

void OrbitVideoOverlayWindowMac::BuildWindow() {
  const NSRect content_rect =
      NSMakeRect(0, 0, kMinContentWidth, kMinContentHeight);
  native_->panel = [[OrbitPiPPanel alloc]
      initWithContentRect:content_rect
                styleMask:NSWindowStyleMaskTitled |
                          NSWindowStyleMaskFullSizeContentView |
                          NSWindowStyleMaskResizable |
                          NSWindowStyleMaskNonactivatingPanel
                  backing:NSBackingStoreBuffered
                    defer:NO];
  native_->panel.releasedWhenClosed = NO;
  native_->panel.titlebarAppearsTransparent = YES;
  native_->panel.titleVisibility = NSWindowTitleHidden;
  [native_->panel standardWindowButton:NSWindowCloseButton].hidden = YES;
  [native_->panel standardWindowButton:NSWindowMiniaturizeButton].hidden = YES;
  [native_->panel standardWindowButton:NSWindowZoomButton].hidden = YES;
  native_->panel.opaque = NO;
  native_->panel.backgroundColor = [NSColor clearColor];
  native_->panel.hasShadow = YES;
  native_->panel.level = NSFloatingWindowLevel;
  native_->panel.hidesOnDeactivate = NO;
  native_->panel.movableByWindowBackground = YES;
  native_->panel.collectionBehavior =
      NSWindowCollectionBehaviorCanJoinAllSpaces |
      NSWindowCollectionBehaviorFullScreenAuxiliary;
  native_->panel.contentMinSize = NSMakeSize(kMinContentWidth, kMinContentHeight);

  native_->bridge = [[OrbitPiPBridge alloc] init];
  native_->bridge.owner = this;
  native_->panel.delegate = native_->bridge;

  NSView* container = [[NSView alloc] initWithFrame:content_rect];
  container.wantsLayer = YES;
  container.layer.backgroundColor = [NSColor blackColor].CGColor;
  container.layer.cornerRadius = 10;
  container.layer.masksToBounds = YES;
  container.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  native_->panel.contentView = container;

  // Layer-hosting and deliberately childless: ui::DisplayCALayerTree owns
  // every sublayer of this view's layer, so AppKit must not add any of its
  // own. The controls are a sibling ordered above it.
  native_->surface_view = [[NSView alloc] initWithFrame:content_rect];
  CALayer* surface_layer = [CALayer layer];
  surface_layer.backgroundColor = [NSColor blackColor].CGColor;
  display_ca_layer_tree_ = std::make_unique<ui::DisplayCALayerTree>(surface_layer);
  native_->surface_view.layer = surface_layer;
  native_->surface_view.wantsLayer = YES;
  native_->surface_view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [container addSubview:native_->surface_view];

  native_->controls = [[OrbitPiPControlsView alloc] initWithFrame:content_rect];
  native_->controls.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  native_->controls.alphaValue = 0;
  [native_->controls addControl:kControlClose symbol:@"xmark" primary:NO];
  [native_->controls addControl:kControlBackToTab symbol:@"pip.exit" primary:NO];
  [native_->controls addControl:kControlPlayPause symbol:@"play.fill" primary:YES];
  [native_->controls addControl:kControlPreviousTrack symbol:@"backward.end.fill" primary:NO];
  [native_->controls addControl:kControlNextTrack symbol:@"forward.end.fill" primary:NO];
  [native_->controls addControl:kControlSkipAd symbol:@"forward.frame.fill" primary:NO];
  [native_->controls addControl:kControlToggleMute symbol:@"speaker.wave.2.fill" primary:NO];
  [native_->controls addControl:kControlToggleMicrophone symbol:@"mic.fill" primary:NO];
  [native_->controls addControl:kControlToggleCamera symbol:@"video.fill" primary:NO];
  [native_->controls addControl:kControlHangUp symbol:@"phone.down.fill" primary:NO];
  [native_->controls addControl:kControlPreviousSlide
                         symbol:@"arrowtriangle.left.square.fill"
                        primary:NO];
  [native_->controls addControl:kControlNextSlide
                         symbol:@"arrowtriangle.right.square.fill"
                        primary:NO];
  native_->controls.bridge = native_->bridge;
  [container addSubview:native_->controls
             positioned:NSWindowAbove
             relativeTo:native_->surface_view];

  SetControlVisible(kControlClose, true);
  SetControlVisible(kControlBackToTab, true);
  SetControlVisible(kControlToggleMute, true);

  compositor_ =
      std::make_unique<ui::RecyclableCompositorMac>(content::GetContextFactory());
  root_layer_ = std::make_unique<ui::LayerSolidColor>();
  root_layer_->SetColor(SkColors::kBlack);
  root_layer_->SetBounds(
      gfx::Rect(gfx::Size(kMinContentWidth, kMinContentHeight)));
  video_layer_ = std::make_unique<ui::LayerTextured>();
  video_layer_->SetFillsBoundsOpaquely(true);
  video_layer_->SetBounds(root_layer_->bounds());
  root_layer_->Add(video_layer_.get());

  compositor_->compositor()->SetRootLayer(root_layer_.get());
  compositor_->compositor()->SetBackgroundColor(SK_ColorBLACK);
  compositor_->widget()->SetNSView(this);
  UpdateCompositorSurface();
  compositor_->Unsuspend();
  UpdateSymbols();
}

void OrbitVideoOverlayWindowMac::TearDownCompositor() {
  if (compositor_) {
    MaybeUnregisterFrameSinkHierarchy();
    compositor_->widget()->ResetNSView();
    compositor_->compositor()->SetRootLayer(nullptr);
    compositor_.reset();
  }
  display_ca_layer_tree_.reset();
  video_layer_.reset();
  root_layer_.reset();
}

void OrbitVideoOverlayWindowMac::DestroyWindow() {
  if (!native_->panel) {
    return;
  }
  // Cleared before -close so windowWillClose: cannot re-enter this object.
  native_->bridge.owner = nullptr;
  native_->panel.delegate = nil;
  native_->controls.bridge = nil;
  [native_->panel orderOut:nil];
  [native_->panel close];
  native_->panel = nil;
  native_->surface_view = nil;
  native_->controls = nil;
  native_->bridge = nil;
}

void OrbitVideoOverlayWindowMac::MaybeUnregisterFrameSinkHierarchy() {
  if (!has_registered_frame_sink_hierarchy_ || !compositor_) {
    return;
  }
  compositor_->compositor()->RemoveChildFrameSink(surface_id_.frame_sink_id());
  has_registered_frame_sink_hierarchy_ = false;
}

display::Display OrbitVideoOverlayWindowMac::CurrentDisplay() const {
  display::Screen* screen = display::Screen::Get();
  if (!screen) {
    return display::Display();
  }
  if (native_->panel) {
    return screen->GetDisplayMatching(
        gfx::ScreenRectFromNSRect(native_->panel.frame));
  }
  return screen->GetPrimaryDisplay();
}

void OrbitVideoOverlayWindowMac::UpdateCompositorSurface() {
  if (!compositor_ || !native_->panel) {
    return;
  }
  const NSSize content = native_->panel.contentView.bounds.size;
  const gfx::Size size_in_dip(content.width, content.height);
  if (size_in_dip.IsEmpty()) {
    return;
  }
  const display::Display display = CurrentDisplay();
  const gfx::Size size_pixels = gfx::ToRoundedSize(
      gfx::ConvertSizeToPixels(size_in_dip, display.device_scale_factor()));
  compositor_->UpdateSurface(size_pixels, display.device_scale_factor(),
                             display.GetColorSpaces(), display.id());
  root_layer_->SetBounds(gfx::Rect(size_in_dip));
  video_layer_->SetBounds(gfx::Rect(size_in_dip));
  if (video_layer_->HasExternalContent()) {
    video_layer_->SetSurfaceSize(size_in_dip);
  }
}

void OrbitVideoOverlayWindowMac::PushSurfaceToLayer() {
  if (!video_layer_ || !surface_id_.is_valid()) {
    return;
  }
  video_layer_->SetShowSurface(surface_id_, root_layer_->bounds().size(),
                               SkColors::kBlack,
                               cc::DeadlinePolicy::UseDefaultDeadline(),
                               /*stretch_content_to_fill_bounds=*/true);
}

gfx::Size OrbitVideoOverlayWindowMac::FitToAspectRatio(
    const gfx::Size& desired) const {
  gfx::Size size = desired;
  const gfx::Rect work_area = CurrentDisplay().work_area();
  if (!work_area.IsEmpty()) {
    size.SetToMin(gfx::Size(work_area.width() * 0.8, work_area.height() * 0.8));
  }
  size.SetToMax(gfx::Size(kMinContentWidth, kMinContentHeight));

  if (natural_size_.IsEmpty()) {
    return size;
  }
  const double aspect =
      static_cast<double>(natural_size_.width()) / natural_size_.height();
  int width = size.width();
  int height = static_cast<int>(std::lround(width / aspect));
  if (height > size.height()) {
    height = size.height();
    width = static_cast<int>(std::lround(height * aspect));
  }
  return gfx::Size(std::max(width, 1), std::max(height, 1));
}

void OrbitVideoOverlayWindowMac::ApplyContentSize(const gfx::Size& size_in_dip) {
  if (!native_->panel) {
    return;
  }
  const NSRect content =
      [native_->panel contentRectForFrameRect:native_->panel.frame];
  const NSRect new_content =
      NSMakeRect(NSMinX(content), NSMaxY(content) - size_in_dip.height(),
                 size_in_dip.width(), size_in_dip.height());
  [native_->panel setFrame:[native_->panel frameRectForContentRect:new_content]
                   display:YES];
  UpdateCompositorSurface();
  PushSurfaceToLayer();
}

void OrbitVideoOverlayWindowMac::AcceleratedWidgetCALayerParamsUpdated(
    gfx::CALayerParams ca_layer_params) {
  if (display_ca_layer_tree_) {
    display_ca_layer_tree_->UpdateCALayerTree(std::move(ca_layer_params));
  }
}

bool OrbitVideoOverlayWindowMac::IsActive() const {
  return native_->panel && native_->panel.isKeyWindow;
}

// Only called from WebContentsDestroyed(). Notifying the controller here would delete
// `this` mid-call (OnWindowDestroyed resets its owning unique_ptr), so it's skipped.
void OrbitVideoOverlayWindowMac::Close() {
  if (is_torn_down_) {
    return;
  }
  is_torn_down_ = true;
  StopProgressTimer();
  TearDownCompositor();
  DestroyWindow();
}

void OrbitVideoOverlayWindowMac::ShowInactive() {
  if (!native_->panel) {
    return;
  }
  if (!has_been_shown_) {
    has_been_shown_ = true;
    const gfx::Rect work_area = CurrentDisplay().work_area();
    const gfx::Size size = FitToAspectRatio(
        gfx::Size(work_area.width() / 4, work_area.height() / 4));
    const int margin = 24;
    const gfx::Rect placed(work_area.right() - size.width() - margin,
                           work_area.bottom() - size.height() - margin,
                           size.width(), size.height());
    [native_->panel
        setFrame:[native_->panel
                     frameRectForContentRect:gfx::ScreenRectToNSRect(placed)]
         display:NO];
    UpdateCompositorSurface();
    PushSurfaceToLayer();
  }
  [native_->panel orderFrontRegardless];
  StartProgressTimerIfNeeded();
}

void OrbitVideoOverlayWindowMac::Hide() {
  StopProgressTimer();
  if (native_->panel) {
    [native_->panel orderOut:nil];
  }
}

bool OrbitVideoOverlayWindowMac::IsVisible() const {
  return native_->panel && native_->panel.isVisible;
}

gfx::Rect OrbitVideoOverlayWindowMac::GetBounds() {
  if (!native_->panel) {
    return gfx::Rect();
  }
  return gfx::ScreenRectFromNSRect(native_->panel.frame);
}

void OrbitVideoOverlayWindowMac::UpdateNaturalSize(const gfx::Size& natural_size) {
  if (natural_size.IsEmpty() || !native_->panel) {
    return;
  }
  natural_size_ = natural_size;
  native_->panel.contentAspectRatio =
      NSMakeSize(natural_size.width(), natural_size.height());

  const NSRect content =
      [native_->panel contentRectForFrameRect:native_->panel.frame];
  gfx::Size desired(NSWidth(content), NSHeight(content));
  if (!has_been_shown_) {
    const gfx::Rect work_area = CurrentDisplay().work_area();
    desired = gfx::Size(work_area.width() / 4, work_area.height() / 4);
  }
  ApplyContentSize(FitToAspectRatio(desired));
}

void OrbitVideoOverlayWindowMac::SetSurfaceId(const viz::SurfaceId& surface_id) {
  if (!compositor_ || !video_layer_) {
    return;
  }
  MaybeUnregisterFrameSinkHierarchy();
  surface_id_ = surface_id;
  compositor_->compositor()->AddChildFrameSink(surface_id.frame_sink_id());
  has_registered_frame_sink_hierarchy_ = true;
  PushSurfaceToLayer();
}

void OrbitVideoOverlayWindowMac::SetPlaybackState(PlaybackState playback_state) {
  playback_state_ = playback_state;
  UpdateSymbols();
  if (playback_state == kPlaying) {
    StartProgressTimerIfNeeded();
  } else {
    StopProgressTimer();
    RefreshProgress();
  }
}

void OrbitVideoOverlayWindowMac::UpdateSymbols() {
  [native_->controls buttonForControl:kControlPlayPause].image =
      SymbolImage(playback_state_ == kPlaying ? @"pause.fill" : @"play.fill", 19);
  [native_->controls buttonForControl:kControlToggleMute].image = SymbolImage(
      media_muted_ ? @"speaker.slash.fill" : @"speaker.wave.2.fill", 12);
  [native_->controls buttonForControl:kControlToggleMicrophone].image =
      SymbolImage(microphone_muted_ ? @"mic.slash.fill" : @"mic.fill", 12);
  [native_->controls buttonForControl:kControlToggleCamera].image =
      SymbolImage(camera_on_ ? @"video.fill" : @"video.slash.fill", 12);
}

void OrbitVideoOverlayWindowMac::SetControlVisible(NSInteger control,
                                                   bool is_visible) {
  requested_visibility_[control] = is_visible;
  const bool is_window_chrome =
      control == kControlClose || control == kControlBackToTab;
  const bool effective =
      is_visible && (playback_controls_visible_ || is_window_chrome);
  [native_->controls buttonForControl:control].hidden = !effective;
  native_->controls.needsLayout = YES;
}

void OrbitVideoOverlayWindowMac::SetPlayPauseButtonVisibility(bool is_visible) {
  show_play_pause_button_ = is_visible;
  SetControlVisible(kControlPlayPause, is_visible);
}

void OrbitVideoOverlayWindowMac::SetSkipAdButtonVisibility(bool is_visible) {
  SetControlVisible(kControlSkipAd, is_visible);
}

void OrbitVideoOverlayWindowMac::SetNextTrackButtonVisibility(bool is_visible) {
  SetControlVisible(kControlNextTrack, is_visible);
}

void OrbitVideoOverlayWindowMac::SetPreviousTrackButtonVisibility(bool is_visible) {
  SetControlVisible(kControlPreviousTrack, is_visible);
}

void OrbitVideoOverlayWindowMac::SetHidePictureInPictureButtonVisibility(
    bool is_visible) {
  SetControlVisible(kControlBackToTab, is_visible);
}

void OrbitVideoOverlayWindowMac::SetMicrophoneMuted(bool muted) {
  microphone_muted_ = muted;
  UpdateSymbols();
}

void OrbitVideoOverlayWindowMac::SetCameraState(bool turned_on) {
  camera_on_ = turned_on;
  UpdateSymbols();
}

void OrbitVideoOverlayWindowMac::SetMediaMuted(bool muted) {
  media_muted_ = muted;
  UpdateSymbols();
}

void OrbitVideoOverlayWindowMac::SetToggleMicrophoneButtonVisibility(
    bool is_visible) {
  SetControlVisible(kControlToggleMicrophone, is_visible);
}

void OrbitVideoOverlayWindowMac::SetToggleCameraButtonVisibility(bool is_visible) {
  SetControlVisible(kControlToggleCamera, is_visible);
}

void OrbitVideoOverlayWindowMac::SetHangUpButtonVisibility(bool is_visible) {
  SetControlVisible(kControlHangUp, is_visible);
}

void OrbitVideoOverlayWindowMac::SetNextSlideButtonVisibility(bool is_visible) {
  SetControlVisible(kControlNextSlide, is_visible);
}

void OrbitVideoOverlayWindowMac::SetPreviousSlideButtonVisibility(bool is_visible) {
  SetControlVisible(kControlPreviousSlide, is_visible);
}

void OrbitVideoOverlayWindowMac::SetMediaPosition(
    const media_session::MediaPosition& position) {
  media_position_ = position;
  RefreshProgress();
  StartProgressTimerIfNeeded();
}

void OrbitVideoOverlayWindowMac::SetSourceTitle(
    const std::u16string& source_title) {
  native_->controls.titleField.stringValue = base::SysUTF16ToNSString(source_title);
  native_->panel.title = base::SysUTF16ToNSString(source_title);
}

void OrbitVideoOverlayWindowMac::SetFaviconImages(
    const std::vector<media_session::MediaImage>& images) {
  media_session::MediaImageManager manager(16, 16);
  std::optional<media_session::MediaImage> image = manager.SelectImage(images);
  if (!image) {
    native_->controls.faviconView.image = nil;
    return;
  }
  controller_->GetMediaImage(
      *image, 16, 16,
      base::BindOnce(&OrbitVideoOverlayWindowMac::OnFaviconBitmap,
                     weak_factory_.GetWeakPtr()));
}

void OrbitVideoOverlayWindowMac::OnFaviconBitmap(const SkBitmap& bitmap) {
  native_->controls.faviconView.image = ImageFromSkBitmap(bitmap);
}

void OrbitVideoOverlayWindowMac::SetPlaybackControlsVisibility(bool is_visible) {
  if (playback_controls_visible_ == is_visible) {
    return;
  }
  playback_controls_visible_ = is_visible;
  const std::map<NSInteger, bool> requested = requested_visibility_;
  for (const auto& [control, was_requested] : requested) {
    SetControlVisible(control, was_requested);
  }
  native_->controls.progressView.hidden = !is_visible;
}

void OrbitVideoOverlayWindowMac::SetImmersiveVideoOptions(
    const content::ImmersiveOptions&) {
  // Immersive playback is Android XR only and gated on
  // WebContentsDelegate::IsImmersivePlaybackEnabled(), which Orbit leaves
  // false, so content never reaches this.
}

void OrbitVideoOverlayWindowMac::RefreshProgress() {
  double fraction = 0;
  if (media_position_.has_value() && media_position_->duration().is_positive()) {
    fraction = media_position_->GetPosition().InSecondsF() /
               media_position_->duration().InSecondsF();
  }
  native_->controls.progressView.fraction = fraction;
  [native_->controls.progressView setNeedsDisplay:YES];
}

void OrbitVideoOverlayWindowMac::StartProgressTimerIfNeeded() {
  if (native_->progress_timer || !media_position_.has_value() ||
      playback_state_ != kPlaying) {
    return;
  }
  OrbitPiPBridge* bridge = native_->bridge;
  native_->progress_timer =
      [NSTimer scheduledTimerWithTimeInterval:0.25
                                      repeats:YES
                                        block:^(NSTimer* timer) {
                                          [bridge progressTick];
                                        }];
}

void OrbitVideoOverlayWindowMac::StopProgressTimer() {
  [native_->progress_timer invalidate];
  native_->progress_timer = nil;
}

void OrbitVideoOverlayWindowMac::OnProgressTick() {
  RefreshProgress();
}

void OrbitVideoOverlayWindowMac::OnHoverChanged(bool hovering) {
  OrbitPiPControlsView* controls = native_->controls;
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext* context) {
    context.duration = 0.15;
    controls.animator.alphaValue = hovering ? 1.0 : 0.0;
  }];
}

void OrbitVideoOverlayWindowMac::OnWindowResized() {
  UpdateCompositorSurface();
  PushSurfaceToLayer();
  controller_->UpdateLayerBounds();
}

// Only reached for a close Orbit did not initiate (DestroyWindow clears the
// delegate first). OnWindowDestroyed destroys `this`, so it goes through a
// posted task rather than running inside AppKit's own teardown.
void OrbitVideoOverlayWindowMac::OnWindowWillClose() {
  if (is_torn_down_) {
    return;
  }
  is_torn_down_ = true;
  StopProgressTimer();
  TearDownCompositor();
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE,
      base::BindOnce(
          &OrbitVideoOverlayWindowMac::NotifyControllerWindowDestroyed,
          weak_factory_.GetWeakPtr(), show_play_pause_button_));
}

void OrbitVideoOverlayWindowMac::NotifyControllerWindowDestroyed(
    bool should_pause_video) {
  if (notified_destroyed_) {
    return;
  }
  notified_destroyed_ = true;
  controller_->OnWindowDestroyed(should_pause_video);
}

void OrbitVideoOverlayWindowMac::OnSeekToFraction(double fraction) {
  if (!media_position_.has_value()) {
    return;
  }
  controller_->SeekTo(media_position_->duration() *
                      std::clamp(fraction, 0.0, 1.0));
}

void OrbitVideoOverlayWindowMac::OnControlActivated(NSInteger control) {
  switch (control) {
    case kControlClose:
      controller_->Close(/*should_pause_video=*/show_play_pause_button_);
      return;
    case kControlBackToTab:
      controller_->CloseAndFocusInitiator();
      return;
    case kControlPlayPause:
      playback_state_ = controller_->TogglePlayPause() ? kPlaying : kPaused;
      UpdateSymbols();
      return;
    case kControlPreviousTrack:
      controller_->PreviousTrack();
      return;
    case kControlNextTrack:
      controller_->NextTrack();
      return;
    case kControlSkipAd:
      controller_->SkipAd();
      return;
    case kControlToggleMute:
      controller_->RequestMute(!controller_->GetMuteStatus());
      return;
    case kControlToggleMicrophone:
      controller_->ToggleMicrophone();
      return;
    case kControlToggleCamera:
      controller_->ToggleCamera();
      return;
    case kControlHangUp:
      controller_->HangUp();
      return;
    case kControlPreviousSlide:
      controller_->PreviousSlide();
      return;
    case kControlNextSlide:
      controller_->NextSlide();
      return;
    default:
      return;
  }
}

}  // namespace orbit

@implementation OrbitPiPBridge
@synthesize owner = _owner;

- (void)controlClicked:(NSButton*)sender {
  if (_owner) {
    _owner->OnControlActivated(sender.tag);
  }
}

- (void)seekToFraction:(double)fraction {
  if (_owner) {
    _owner->OnSeekToFraction(fraction);
  }
}

- (void)hoverChanged:(BOOL)hovering {
  if (_owner) {
    _owner->OnHoverChanged(hovering);
  }
}

- (void)progressTick {
  if (_owner) {
    _owner->OnProgressTick();
  }
}

- (void)windowDidResize:(NSNotification*)notification {
  if (_owner) {
    _owner->OnWindowResized();
  }
}

- (void)windowWillClose:(NSNotification*)notification {
  if (_owner) {
    _owner->OnWindowWillClose();
  }
}

@end
