import Foundation

public enum PictureInPictureScript {

    public static let logPrefix = "[Orbit] Picture-in-Picture"

    /// Run via DevTools `Runtime.evaluate` with `userGesture: true` — a plain
    /// `ExecuteJavaScript` grants no transient activation for `requestPictureInPicture()`.
    public static let source = """
    (function() {
      var prefix = '\(logPrefix)';
      function report(message) {
        try { console.error(prefix + ': ' + message); } catch (e) {}
      }
      function describe(error) {
        if (!error) { return 'unknown error'; }
        if (error.name && error.message) { return error.name + ': ' + error.message; }
        return String(error);
      }
      try {
        if (document.pictureInPictureElement) {
          var exiting = document.exitPictureInPicture();
          if (exiting && exiting.catch) {
            exiting.catch(function(e) { report('exit rejected — ' + describe(e)); });
          }
          return true;
        }
        var all = Array.prototype.slice.call(document.querySelectorAll('video'));
        var presented = all.filter(function(v) {
          return v.webkitPresentationMode === 'picture-in-picture';
        });
        if (presented.length > 0) {
          presented.forEach(function(v) { v.webkitSetPresentationMode('inline'); });
          return true;
        }

        if (all.length === 0) {
          report('this page has no <video> element to present.');
          return false;
        }
        var target = all.filter(function(v) { return !v.paused; })[0] || all[0];
        if (target.disablePictureInPicture) {
          report('the page has set disablePictureInPicture on its video.');
          return false;
        }
        if (target.requestPictureInPicture) {
          var entering = target.requestPictureInPicture();
          if (entering && entering.catch) {
            entering.catch(function(e) { report('request rejected — ' + describe(e)); });
          }
          return true;
        }
        if (target.webkitSetPresentationMode) {
          target.webkitSetPresentationMode('picture-in-picture');
          return true;
        }
        report('this engine exposes neither requestPictureInPicture nor webkitSetPresentationMode.');
        return false;
      } catch (e) {
        report('failed — ' + describe(e));
        return false;
      }
    })();
    """
}
