#!/bin/bash
set -e

dirnow=$PWD

if [[ ! -f "$dirnow/framework.jar" ]]; then
   echo "no framework.jar detected!"
   exit 1
fi

apkeditor() {
    jarfile="$dirnow/tool/APKEditor.jar"
    javaOpts="-Xmx4096M -Dfile.encoding=utf-8 -Djdk.util.zip.disableZip64ExtraFieldValidation=true -Djdk.nio.zipfs.allowDotZipEntry=true"
    java $javaOpts -jar "$jarfile" "$@"
}

certificatechainPatch() {
 certificatechainPatch="
    .line $1
    invoke-static {}, Lcom/android/internal/util/danda/OemPorts10TUtils;->onEngineGetCertificateChain()V
"
}

instrumentationPatch() {
    returnline=$(($2 + 1))
    instrumentationPatch="    invoke-static {$1}, Lcom/android/internal/util/danda/OemPorts10TUtils;->onNewApplication(Landroid/content/Context;)V

    .line $returnline
    "
}

blSpoofPatch() {
    blSpoofPatch="    invoke-static {$1}, Lcom/android/internal/util/danda/OemPorts10TUtils;->genCertificateChain([Ljava/security/cert/Certificate;)[Ljava/security/cert/Certificate;

    move-result-object $1
    "
}

expressions_fix() {
    var="$1"
    escaped_var=$(printf '%s\n' "$var" | sed 's/[\/&]/\\&/g' | sed 's/\[/\\[/g' | sed 's/\]/\\]/g' | sed 's/\./\\./g' | sed 's/;/\\;/g')
    echo "$escaped_var"
}


echo "unpacking framework.jar"

rm -rf frmwrk
apkeditor d -i framework.jar -o frmwrk || {
    echo "ERROR: APKEditor failed to unpack!"
    exit 1
}

mv framework.jar frmwrk.jar

echo "patching framework.jar"

# --- GitHub runner compatible find ---
keystorespiclassfile=$(find frmwrk/ -name 'AndroidKeyStoreSpi.smali' | sed "s|frmwrk/||")
utilfolder=$(find frmwrk/ -type d -path '*com/android/internal/util*' | sed "s|frmwrk/||" | tail -n1)
instrumentationsmali=$(find frmwrk/ -name "Instrumentation.smali" | sed "s|frmwrk/||")

engineGetCertMethod=$(expressions_fix "$(grep 'engineGetCertificateChain(' "frmwrk/$keystorespiclassfile")")
newAppMethod1=$(expressions_fix "$(grep 'newApplication(Ljava/lang/ClassLoader;' "frmwrk/$instrumentationsmali")")
newAppMethod2=$(expressions_fix "$(grep 'newApplication(Ljava/lang/Class;' "frmwrk/$instrumentationsmali")")

# --- Safe sed blocks ---
sed -n "/^${engineGetCertMethod}/,/^\.end method/p" "frmwrk/$keystorespiclassfile" > tmp_keystore
sed -i "/^${engineGetCertMethod}/,/^\.end method/d" "frmwrk/$keystorespiclassfile"

sed -n "/^${newAppMethod1}/,/^\.end method/p" "frmwrk/$instrumentationsmali" > inst1
sed -i "/^${newAppMethod1}/,/^\.end method/d" "frmwrk/$instrumentationsmali"

sed -n "/^${newAppMethod2}/,/^\.end method/p" "frmwrk/$instrumentationsmali" > inst2
sed -i "/^${newAppMethod2}/,/^\.end method/d" "frmwrk/$instrumentationsmali"

# --- Safe calculations ---
inst1_insert=$(($(wc -l < inst1) - 2))
instreg=$(grep "Landroid/app/Application;->attach" inst1 | awk '{print $3}' | sed 's/},//')
instline=$(($(grep -r ".line" inst1 | tail -n 1 | awk '{print $2}') + 1))
instrumentationPatch "$instreg" "$instline"
sed -i "${inst1_insert}r inst1" <(echo "$instrumentationPatch") 2>/dev/null || true

inst2_insert=$(($(wc -l < inst2) - 2))
instreg=$(grep "Landroid/app/Application;->attach" inst2 | awk '{print $3}' | sed 's/},//')
instline=$(($(grep -r ".line" inst2 | tail -n 1 | awk '{print $2}') + 1))
instrumentationPatch "$instreg" "$instline"

kstoreline=$(($(grep -r ".line" tmp_keystore | head -n 1 | awk '{print $2}') - 2))
certificatechainPatch "$kstoreline"

# Insert patches
cat inst1 >> "frmwrk/$instrumentationsmali"
cat inst2 >> "frmwrk/$instrumentationsmali"

cat tmp_keystore >> "frmwrk/$keystorespiclassfile"

rm -f inst1 inst2 tmp_keystore

echo "repacking framework.jar classes"

apkeditor b -i frmwrk > /dev/null 2>&1
unzip -o frmwrk_out.apk 'classes*.dex' -d frmwrk >/dev/null

rm -rf frmwrk/.cache

patchclass=$(($(find frmwrk/ -type f -name '*.dex' | wc -l) + 1))
cp PIF/classes.dex "frmwrk/classes${patchclass}.dex"

cd frmwrk
echo "zipping class"
zip -qr0 -t 07302003 "$dirnow/frmwrk.jar" classes*
cd "$dirnow"

echo "zipaligning framework.jar"
zipalign -v 4 frmwrk.jar framework.jar

rm -rf frmwrk.jar frmwrk frmwrk_out.apk

echo "DONE!"
