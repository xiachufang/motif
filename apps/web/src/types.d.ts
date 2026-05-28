// Ambient declarations for assets imported only for their side-effects.

declare module "*.css";
declare module "*.svg";
declare module "*.png";
declare module "*.jpg";
declare module "*.jpeg";

// diff2html ships its own types but the stylesheet path needs an opaque module.
declare module "diff2html/bundles/css/diff2html.min.css";
declare module "highlight.js/styles/atom-one-dark.min.css";
declare module "@xterm/xterm/css/xterm.css";
