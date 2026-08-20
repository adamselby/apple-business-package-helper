#!/bin/zsh
# Usage: ./fetch_workbrew_pkg_info.sh [url] [outputDir]

# Pass a URL that serves a .pkg and extract the info needed for Apple Business (Manager) directly from the package itself, saving the details to text clippings
# SHA-256, bundleID, app version, app icon, Team ID, and full download URL

set -euo pipefail

defaultUrl="https://console.workbrew.com/downloads/macos" # Default URL to parse if nothing else is passed
packageUrl="${1:-$defaultUrl}"
outputDir="${2:-./pkg-info}"
maxIconDimension=1024
maxIconBytes=$((10 * 1024 * 1024))

# WARNING: Do not modify, this is a bit of a hack
# This is a fixed byte templates for the classic resource-fork clipping format, which is old
# Claude reverse-engineered this from real Finder-generated .textClipping files
# 'drag' resource and resource-map layout never change, only 4 data-offset fields do)
dragHex="00000001000000000000000000000003757478740000010000000000000000007574663800000100000000000000000054455854000001000000000000000000"
resourceMapTemplateHex="000000000000000000000000000000000000000000000000001c006e00037574787400000022757466380000002e544558540000003a64726167000000460100ffff00000000000000000100ffff00000084000000000100ffff000000c8000000000080ffff0000010c00000000"
finderInfoHex="636c70744d4143530010$(printf '00%.0s' {1..22})"

beUint32Hex() { printf '%08x' "$1" }
beUint24Hex() { printf '%06x' "$1" }

patchResourceMap() {
    local -a offsetPositions=(67 79 91 103)
    local -a offsetValues=("$1" "$2" "$3" "$4")
    local result="" prev=0 pos val start end
    local i
    for i in 1 2 3 4; do
        pos=${offsetPositions[i]}
        val=${offsetValues[i]}
        start=$(( prev * 2 + 1 ))
        end=$(( pos * 2 ))
        result+="${resourceMapTemplateHex[$start,$end]}"
        result+="$(beUint24Hex "$val")"
        prev=$(( pos + 3 ))
    done
    start=$(( prev * 2 + 1 ))
    result+="${resourceMapTemplateHex[$start,220]}"
    print -r -- "$result"
}

# makeTextClipping <text> <outputPath>
makeTextClipping() {
    local text="$1" out="$2"

    local utf8Hex utf16Hex
    utf8Hex=$(printf '%s' "$text" | xxd -p | tr -d '\n')
    utf16Hex=$(printf '%s' "$text" | iconv -f UTF-8 -t UTF-16LE | xxd -p | tr -d '\n')

    # --- data fork: UTI-Data binary plist, built via plutil (no python) ---
    local asciiBase64 utf16Base64 escapedText xmlTempFile
    asciiBase64=$(print -r -- "$utf8Hex" | xxd -r -p | base64)
    utf16Base64=$(print -r -- "$utf16Hex" | xxd -r -p | base64)
    escapedText=$(printf '%s' "$text" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
    xmlTempFile=$(mktemp)
    cat > "$xmlTempFile" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>UTI-Data</key>
	<dict>
		<key>com.apple.traditional-mac-plain-text</key>
		<data>
		$asciiBase64
		</data>
		<key>public.utf16-plain-text</key>
		<data>
		$utf16Base64
		</data>
		<key>public.utf8-plain-text</key>
		<string>$escapedText</string>
	</dict>
</dict>
</plist>
PLIST
    plutil -convert binary1 "$xmlTempFile" -o "$out"
    rm -f "$xmlTempFile"

    # --- resource fork: utxt/utf8/TEXT/drag resources, all id 256 except drag(128) ---
    local utxtLength=$(( ${#utf16Hex} / 2 ))
    local utf8Length=$(( ${#utf8Hex} / 2 ))
    local textLength=$(( ${#utf8Hex} / 2 ))
    local dragLength=64

    local utxtOffset=0
    local utf8Offset=$(( utxtOffset + 4 + utxtLength ))
    local textOffset=$(( utf8Offset + 4 + utf8Length ))
    local dragOffset=$(( textOffset + 4 + textLength ))
    local dataLength=$(( dragOffset + 4 + dragLength ))
    local mapLength=110
    local dataOffset=256
    local mapOffset=$(( dataOffset + dataLength ))

    local headerHex="$(beUint32Hex "$dataOffset")$(beUint32Hex "$mapOffset")$(beUint32Hex "$dataLength")$(beUint32Hex "$mapLength")"
    local padHex
    padHex=$(printf '00%.0s' {1..240})

    local dataHex="$(beUint32Hex "$utxtLength")${utf16Hex}$(beUint32Hex "$utf8Length")${utf8Hex}$(beUint32Hex "$textLength")${utf8Hex}$(beUint32Hex "$dragLength")${dragHex}"
    local resourceMapHex
    resourceMapHex=$(patchResourceMap "$utxtOffset" "$utf8Offset" "$textOffset" "$dragOffset")

    print -r -- "${headerHex}${padHex}${dataHex}${resourceMapHex}" | xxd -r -p > "${out}/..namedfork/rsrc"

    xattr -wx com.apple.FinderInfo "$finderInfoHex" "$out"
}

mkdir -p "$outputDir"
cd "$outputDir"

echo "Downloading…"
curl -sL -D ./_headers.txt -o ./_download.pkg "$packageUrl"

fileName=$(grep -i '^content-disposition:' ./_headers.txt | tail -n1 \
    | grep -oE 'filename="?[^";]+' | sed -E 's/filename="?//' | tr -d '\r')
pkgFile="${fileName:-package.pkg}"
mv ./_download.pkg "$pkgFile"
rm -f ./_headers.txt
echo "Downloaded: $pkgFile"

echo "Computing hash…"
sha256=$(shasum -a 256 "$pkgFile" | awk '{print $1}')

echo "Expanding package for inspection…"
rm -rf ./_expanded
pkgutil --expand-full "$pkgFile" ./_expanded

# Product archives can bundle several component packages, so we treat the component with the largest installed payload as the primary one for Bundle ID + version which is probably a relatively safe bet?

mainPkgInfo=""
mainKbytes=-1
while IFS= read -r pkgInfoFile; do
    kbytes=$(xmllint --xpath 'string(//pkg-info/payload/@installKBytes)' "$pkgInfoFile" 2>/dev/null || echo 0)
    [[ "$kbytes" =~ ^[0-9]+$ ]] || kbytes=0
    if (( kbytes > mainKbytes )); then
        mainKbytes=$kbytes
        mainPkgInfo="$pkgInfoFile"
    fi
done < <(find ./_expanded -maxdepth 2 -name PackageInfo)

bundleId=$(xmllint --xpath 'string(//pkg-info/@identifier)' "$mainPkgInfo" 2>/dev/null || true)
version=$(xmllint --xpath 'string(//pkg-info/@version)' "$mainPkgInfo" 2>/dev/null || true)

if [[ -z "$bundleId" && -f ./_expanded/Distribution ]]; then
    bundleId=$(xmllint --xpath 'string(//pkg-ref[@id][1]/@id)' ./_expanded/Distribution 2>/dev/null || true)
    version=$(xmllint --xpath 'string(//pkg-ref[@id][1]/@version)' ./_expanded/Distribution 2>/dev/null || true)
fi

echo "Locating app bundle + icon…"
appDir=$(find ./_expanded -iname "*.app" -maxdepth 6 -type d | head -n1)

iconPng=""
if [[ -n "$appDir" && -f "$appDir/Contents/Info.plist" ]]; then
    iconFile=$(/usr/libexec/PlistBuddy -c "Print CFBundleIconFile" "$appDir/Contents/Info.plist" 2>/dev/null || true)
    iconPath=$(find "$appDir/Contents/Resources" -iname "${iconFile:-AppIcon}*.icns" | head -n1)
    if [[ -n "$iconPath" ]]; then
        iconPng="app-icon.png"
        sips -s format png "$iconPath" --out "$iconPng" >/dev/null 2>&1
    fi
fi

# Fall back to the installer's own branding image if no app icon was found (assuming it is present)
if [[ -z "$iconPng" ]]; then
    fallbackPng=$(find ./_expanded/Resources -maxdepth 1 -iname "*.png" 2>/dev/null | head -n1)
    [[ -n "$fallbackPng" ]] && { iconPng="app-icon.png"; cp "$fallbackPng" "$iconPng"; }
fi
if [[ -n "$iconPng" ]]; then
    read -r iconWidth iconHeight <<< "$(sips -g pixelWidth -g pixelHeight "$iconPng" 2>/dev/null | awk '/pixelWidth|pixelHeight/{print $2}' | paste -sd' ' -)"
    iconBytes=$(stat -f%z "$iconPng")
    if (( iconWidth > maxIconDimension || iconHeight > maxIconDimension )); then
        echo "Icon is ${iconWidth}x${iconHeight}, downscaling to fit ${maxIconDimension}x${maxIconDimension}…"
        sips -Z "$maxIconDimension" "$iconPng" >/dev/null 2>&1
    fi
    if (( iconBytes > maxIconBytes )); then
        echo "WARNING: icon is ${iconBytes} bytes, over the ${maxIconBytes}-byte limit." >&2
    fi
fi

echo "Grabbing Developer Team ID from code signing…"
teamId=$(pkgutil --check-signature "$pkgFile" 2>/dev/null \
    | grep -m1 -oE '\(([A-Z0-9]{10})\)' | tr -d '()')

sourceUrl="$packageUrl"

echo "Writing .textClipping files…"
makeTextClipping "$sha256" "./SHA-256.textClipping"
makeTextClipping "${bundleId:-<not found>}" "./Bundle ID.textClipping"
makeTextClipping "${version:-<not found>}" "./Version.textClipping"
makeTextClipping "${teamId:-<not found>}" "./Team ID.textClipping"
makeTextClipping "$sourceUrl" "./Download URL.textClipping"

rm -rf ./_expanded
rm -f "$pkgFile"

echo
printf "%-16s %s\n" "Source URL:"       "$sourceUrl"
printf "%-16s %s\n" "Package Hash:"     "$sha256"
printf "%-16s %s\n" "Bundle ID:"        "${bundleId:-<not found>}"
printf "%-16s %s\n" "Version:"          "${version:-<not found>}"
printf "%-16s %s\n" "Team ID:"          "${teamId:-<not found>}"
printf "%-16s %s\n" "Icon:"             "${iconPng:-<not found>}"
echo "Output written to: $(pwd)"
