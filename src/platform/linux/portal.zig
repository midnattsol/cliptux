//! xdg-desktop-portal clients: Screenshot, ScreenCast, FileChooser, plus
//! desktop notifications.
//!
//! Portal requests answer with a Response signal that may take as long as a
//! person looking at a dialog. Every wait here has a deadline, watches the
//! portal's bus name so a crashed portal fails fast, and reports an
//! explicit Outcome instead of folding everything into one error.
//!
//! Facade over portal/: request (Request, Outcome, deadlines), screenshot,
//! file_chooser, screencast, app_scope (telling the portal our app id)
//! and notify.

const request = @import("portal/request.zig");
const screenshot_mod = @import("portal/screenshot.zig");
const file_chooser = @import("portal/file_chooser.zig");
const screencast = @import("portal/screencast.zig");
const app_scope = @import("portal/app_scope.zig");
const notify_mod = @import("portal/notify.zig");

pub const Outcome = request.Outcome;
pub const Result = request.Result;
pub const timeout_dialog_ms = request.timeout_dialog_ms;
pub const timeout_unfocused_screenshot_ms = request.timeout_unfocused_screenshot_ms;
pub const timeout_quick_ms = request.timeout_quick_ms;
pub const timeout_file_chooser_ms = request.timeout_file_chooser_ms;
pub const bus_name = request.bus_name;
pub const object_path = request.object_path;
pub const watch = request.watch;
pub const Request = request.Request;
pub const call = request.call;

pub const screenshot = screenshot_mod.screenshot;
pub const beginScreenshot = screenshot_mod.beginScreenshot;
pub const screenshotUri = screenshot_mod.screenshotUri;
pub const readAndUnlink = screenshot_mod.readAndUnlink;

pub const app_id = app_scope.app_id;
pub const connectApp = app_scope.connectApp;
pub const Identity = app_scope.Identity;
pub const registerApp = app_scope.registerApp;
pub const registryMissing = app_scope.registryMissing;
pub const ensureAppScope = app_scope.ensureAppScope;

pub const notify = notify_mod.notify;

pub const SaveFileOptions = file_chooser.SaveFileOptions;
pub const saveFile = file_chooser.saveFile;
pub const FolderOptions = file_chooser.FolderOptions;
pub const beginChooseFolder = file_chooser.beginChooseFolder;
pub const beginSaveFile = file_chooser.beginSaveFile;
pub const savedPath = file_chooser.savedPath;
pub const chosenPath = file_chooser.chosenPath;
pub const chooseFolder = file_chooser.chooseFolder;

pub const Stream = screencast.Stream;
pub const ScStart = screencast.ScStart;
pub const ScreenCastSession = screencast.ScreenCastSession;
pub const scCreateSession = screencast.scCreateSession;
pub const scOpenRemote = screencast.scOpenRemote;
pub const scSelectAndStart = screencast.scSelectAndStart;
pub const parseStartResults = screencast.parseStartResults;
pub const openScreenCast = screencast.openScreenCast;
pub const closeSession = screencast.closeSession;

comptime {
    _ = request;
    _ = screenshot_mod;
    _ = file_chooser;
    _ = screencast;
    _ = app_scope;
    _ = notify_mod;
}
