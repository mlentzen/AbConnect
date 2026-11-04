import Toybox.Lang;

//! The version of the app, bumped by hand.
//!
//! On its own a version number cannot say which build is on the watch: two
//! builds of "0.1.0" are indistinguishable, and the interesting ones are always
//! the intermediate builds. The commit and the build date that the Info screen
//! shows next to this come from build.sh, which knows both and can bake them in.
const APP_VERSION = "0.1.0";
