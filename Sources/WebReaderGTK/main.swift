import Glibc

/// The process entry point. `Application` is held by a top-level `let` for the whole
/// process on purpose: every GTK signal handler recovers it from `user_data`, which
/// `Unmanaged.passUnretained` fills without retaining, so an application object that went
/// away would turn each callback into a use-after-free.
let application = Application()
exit(application.run())
