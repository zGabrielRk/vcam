// Tweak.xm
// LordVCAM - Logos entry point (minimal)
//
// All hooks are installed via MSHookMessageEx in KYCHooks.m.
// This file is intentionally minimal to avoid Logos %hook failures
// when hooked classes don't exist in the current process.

// No %hook blocks — prevents silent load failures when classes
// like BWNodeOutput don't exist in SpringBoard or UIKit apps.
