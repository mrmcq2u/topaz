# Topaz Standalone Build

To get the source code for the Topaz layer, using the following commands
(see [Getting Source](https://fuchsia.googlesource.com/docs/+/master/getting_source.md)
for more information):

```
curl -s "https://fuchsia.googlesource.com/scripts/+/master/bootstrap?format=TEXT" | base64 --decode | bash -s topaz
```

To build the Topaz layer, use the following commands:

## x86-64

```
fx set x86-64
fx full-build
```

## aarch64 (64 bit ARM)

```
fx set aarch64
fx full-build
```
