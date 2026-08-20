# Apple Business Package Helper

Apple Business requires a couple details about custom packages, including a download URL, SHA 256 hash, bundle ID, and more. This helper script downloads a macOS `.pkg` from a URL you pass it and pulls out that information for you. Whether you have to update this package often, or infrequently this helper script can save you time. 

## Why?

This URL can be a stable URL that is always the latest version, a version-specific URL, or any other publicly reachable URL. The helper script will extract all info needed from the package directly, export the icon, and write each value you'll need as a series of `.textClipping` files -- do you know about [textClipping](https://en.wikipedia.org/wiki/TextClipping) files? They're amazing and very uesful -- so that you can easily copy/paste these into Apple Business. If the API expands to include adding or updating custom packages, this script could do that for you too. 

## Usage

```sh
zsh fetch_workbrew_pkg_info.sh [url] [outputDir]
```

- `url` — package URL to fetch. Defaults to the a variable you define.
- `outputDir` — where to write the results. Defaults to `./pkg-info`.

## Requirements

None, just macOS. This uses `curl`, `xmllint`, `pkgutil`, `sips`, `plutil`, and `PlistBuddy` which are all built-in. 