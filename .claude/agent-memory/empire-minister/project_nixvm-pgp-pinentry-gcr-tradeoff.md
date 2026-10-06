---
name: nixvm-pgp-pinentry-gcr-tradeoff
description: BLOCKED 2026-10-06, nothing shipped. pinentry-gtk2 is REMOVED at this pin and every GUI pinentry either brings gcr-3 back (gnome3) or Qt (qt); gpa also drags avahi+openldap, contradicting the brief.
metadata:
  type: project
---

**Status: BLOCKED, nothing committed.** The planned nixvm OpenPGP change —
`gpa` + `programs.gnupg.agent.enable = true` + `pinentryPackage = pkgs.pinentry-gtk2` — cannot
be shipped as specified. Awaiting an operator decision.

## `pinentry-gtk2` does not exist at this pin

The attribute **is** in `attrNames` (so a grep for it "finds" it) but **throws** on eval:

```
error: 'pinentry-gtk2' has been removed as it depended on the deprecated GTK2 engine,
       use pinentry-gnome3 instead.
```

Same shape as `tor-browser-bundle-bin` — an alias removal stub. `pkgs.pinentry` itself also
throws ("Pick an appropriate variant"). **A probe that lists attribute names is not evidence a
package exists**; force the value.

## Every GUI flavour costs something. Measured closures, aarch64-linux:

| attr | paths | gcr-3 | qtbase | GUI prompt? |
|---|---|---|---|---|
| `pinentry-gnome3` | 129 | **1** | 0 | yes |
| `pinentry-qt` | 181 | 0 | **2** | yes |
| `pinentry-egui` | **22** | 0 | 0 | yes (Rust/egui) |
| `pinentry-curses` | 15 | 0 | 0 | **no** — needs a tty |
| `pinentry-tty` | 14 | 0 | 0 | **no** |

`pinentry-gnome3` is what `xfce.nix:169` sets (`mkDefault pkgs.pinentry-gnome3`), and it pulls
**`gcr-3.41.2` + `libsecret`** — i.e. it undoes part of the gnome-keyring removal
([[nixvm-autologin-locker-lockout-trap]]). Note `gcr-4` is **already** in the closure (count 1)
and is unrelated; the regression test is specifically **gcr-3**.

`pinentry-egui` is the only measured option that is GUI-capable, gcr-free and Qt-free, at 22
paths. **Untested here** — nobody has confirmed it renders under XFCE.

## The brief's rationale for `gpa` is partly WRONG — measured

`gpa`'s own closure is **126 paths** and contains **`avahi-0.8` and `openldap-2.6.13`**, which
the brief attributed to `seahorse` as the reason to reject it. gpa does carry the stated
`gtk+3`, `gpgme-2.1.2`, `libassuan-3.0.2`, `libgpg-error-1.61` — but it is not avahi/LDAP-free.
Do not repeat the "gpa avoids the keyserver deps" claim; it does not.

## Facts that DID hold

- `programs.gnupg.agent.pinentryPackage` is the right option (`programs/gnupg.nix:71`), default
  `pkgs.pinentry-curses`, and the module's whole `config` is `mkIf cfg.agent.enable` (`:106`) —
  so pinentry's absence from the closure today was never a broken dependency. `agent.enable`
  evaluates **false**.
- `gnupg.nix:211` explains the gnome3 cost: `services.dbus.packages` is added
  `mkIf (lib.elem "gnome3" (cfg.agent.pinentryPackage.flavors or []))`.
- SSH→PGP conversion remains impossible at this pin; a fresh keypair is generated in the guest
  and the operator's SSH key is not involved.

## Open decision

Pick one: accept `gcr-3` returning (gnome3, simplest), try `pinentry-egui` (smallest, needs a
boot test), take Qt, or drop the GUI prompt (curses — breaks a desktop passphrase prompt).
Also unresolved: whether `gpa` is still the GUI given its avahi/LDAP closure.

`~/.gnupg` would live on the durable **unencrypted** qcow2 and dies with a wipe — any key must
be exported by the operator.
