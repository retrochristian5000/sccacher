#!/bin/bash
set -euo pipefail

SCCACHE="${SCCACHE_PATH:-/sccache/target/debug/sccache}"
TEST_FILE="/sccache/tests/test_clang_multicall.c"

echo "=========================================="
echo "Testing: Clang Compiler"
echo "=========================================="

# Start sccache server
"$SCCACHE" --start-server || true

echo "Test 1: Compile C++ file (cache miss)"
rm -f /tmp/test.o
CXX="$SCCACHE clang++"
$CXX -c "$TEST_FILE" -o /tmp/test.o
test -f /tmp/test.o || { echo "ERROR: No compiler output found"; exit 1; }

echo "Checking stats after first build..."
"$SCCACHE" --show-stats
STATS_JSON=$("$SCCACHE" --show-stats --stats-format=json)

echo "Test 2: Compile again (cache hit expected)"
rm -f /tmp/test.o
$CXX -c "$TEST_FILE" -o /tmp/test.o
test -f /tmp/test.o || { echo "ERROR: No compiler output found"; exit 1; }

echo "Verifying cache hits..."
STATS_JSON=$("$SCCACHE" --show-stats --stats-format=json)
CACHE_HITS=$(echo "$STATS_JSON" | python3 -c "import sys, json; stats = json.load(sys.stdin).get('stats', {}); print(stats.get('cache_hits', {}).get('counts', {}).get('C/C++', 0))")

echo "Cache hits: $CACHE_HITS"

if [ "$CACHE_HITS" -gt 0 ]; then
    echo "PASS: Clang test"
else
    echo "FAIL: Clang test - No cache hits detected"
    echo "$STATS_JSON" | python3 -m json.tool
    exit 1
fi

echo "Test 3: Test ASM"
ASM="$SCCACHE clang++"
$ASM -c /sccache/tests/integration/test_intel_asm.s

DEPFILE="/tmp/test.o.d"
rm -f $DEPFILE
$ASM -c /sccache/tests/integration/test_intel_asm.s -MD -MF $DEPFILE
test ! -f $DEPFILE || { echo "ERROR: Dependency file found"; exit 1; }

echo "Test 4: Test ASM with preprocessor"
$ASM -c /sccache/tests/integration/test_intel_asm_to_preproc.S

$ASM -c /sccache/tests/integration/test_intel_asm_to_preproc.S -MD -MF $DEPFILE
test -f $DEPFILE || { echo "ERROR: Dependency file not found"; exit 1; }
rm -f $DEPFILE

echo "Test 5: Test preprocessed C++ file with dependency arguments (cache miss)"
$CXX -c /sccache/tests/integration/test_preprocessed.ii -o /tmp/test.o -MD -MF $DEPFILE
test -f /tmp/test.o || { echo "ERROR: No compiler output found"; exit 1; }
test ! -f $DEPFILE || { echo "ERROR: Dependency file found"; exit 1; }

echo "Test 6: Test preprocessed C++ file with dependency arguments (cache hit expected)"
$CXX -c /sccache/tests/integration/test_preprocessed.ii -o /tmp/test.o -MD -MF $DEPFILE
test -f /tmp/test.o || { echo "ERROR: No compiler output found"; exit 1; }
test ! -f $DEPFILE || { echo "ERROR: Dependency file found"; exit 1; }


echo "Test 7: Clang PCH macro/AST cache invalidation"
PCH_TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$PCH_TEST_DIR"' EXIT
cat > "$PCH_TEST_DIR/pch_user.cc" <<'EOF'
int whp_probe() { return whp_pch_value(); }
EOF
cat > "$PCH_TEST_DIR/main.cc" <<'EOF'
extern int whp_probe();
#ifndef EXPECTED_PCH_VALUE
#error EXPECTED_PCH_VALUE must be defined
#endif
int main() { return whp_probe() == EXPECTED_PCH_VALUE ? 0 : 1; }
EOF
build_pch() {
    printf '#define WHP_BUILD_VALUE %s\n' "$1" > "$PCH_TEST_DIR/pch.hxx"
    cat >> "$PCH_TEST_DIR/pch.hxx" <<'EOF'
__attribute__((always_inline)) inline int whp_pch_value() { return WHP_BUILD_VALUE; }
EOF
    # This is an implicit PCH producer; it must run through Clang, not a
    # cached object pretending that its preprocessed output captures the AST.
    $CXX -O2 -Xclang -fno-pch-timestamp -x c++-header \
        -c "$PCH_TEST_DIR/pch.hxx" -o "$PCH_TEST_DIR/pch.hxx.pch"
}
compile_pch_user() {
    $CXX -O2 -Xclang -include-pch -Xclang "$PCH_TEST_DIR/pch.hxx.pch" \
        -c "$PCH_TEST_DIR/pch_user.cc" -o "$PCH_TEST_DIR/pch_user.o"
}
check_pch_value() {
    clang++ -DEXPECTED_PCH_VALUE="$1" \
        "$PCH_TEST_DIR/pch_user.o" "$PCH_TEST_DIR/main.cc" \
        -o "$PCH_TEST_DIR/check"
    "$PCH_TEST_DIR/check"
}
# A PCH consumer should be cached, while the PCH producer above remains
# uncacheable. Count hits relative to this point, not earlier compiler tests.
pch_cache_hits() {
    "$SCCACHE" --show-stats --stats-format=json |
        python3 -c 'import json,sys; print(json.load(sys.stdin).get("stats", {}).get("cache_hits", {}).get("counts", {}).get("C/C++", 0))'
}
build_pch 7
compile_pch_user
check_pch_value 7
hits_before_reuse=$(pch_cache_hits)
rm -f "$PCH_TEST_DIR/pch_user.o"
compile_pch_user
check_pch_value 7
hits_after_reuse=$(pch_cache_hits)
test "$hits_after_reuse" -gt "$hits_before_reuse" || {
    echo "FAIL: unchanged PCH consumer did not hit the C++ object cache"
    exit 1
}
# Same consumer source, command line, and output location. Only the PCH
# contents change; stale cache reuse must not preserve the old inline body.
build_pch 19
compile_pch_user
check_pch_value 19
# The new PCH gets its own cache entry. A repeated invocation must hit it.
hits_before_reuse=$(pch_cache_hits)
rm -f "$PCH_TEST_DIR/pch_user.o"
compile_pch_user
check_pch_value 19
hits_after_reuse=$(pch_cache_hits)
test "$hits_after_reuse" -gt "$hits_before_reuse" || {
    echo "FAIL: updated PCH consumer did not hit the C++ object cache"
    exit 1
}
# An unchanged PCH must also distinguish consuming -D macro values.
cat > "$PCH_TEST_DIR/pch_user.cc" <<'EOF'
#ifndef WHP_CONSUMER_VALUE
#error WHP_CONSUMER_VALUE must be defined
#endif
int whp_probe() { return whp_pch_value() + WHP_CONSUMER_VALUE; }
EOF
$CXX -O2 -DWHP_CONSUMER_VALUE=1 \
    -Xclang -include-pch -Xclang "$PCH_TEST_DIR/pch.hxx.pch" \
    -c "$PCH_TEST_DIR/pch_user.cc" -o "$PCH_TEST_DIR/pch_user.o"
check_pch_value 20
$CXX -O2 -DWHP_CONSUMER_VALUE=3 \
    -Xclang -include-pch -Xclang "$PCH_TEST_DIR/pch.hxx.pch" \
    -c "$PCH_TEST_DIR/pch_user.cc" -o "$PCH_TEST_DIR/pch_user.o"
check_pch_value 22
echo "PASS: Clang PCH macro/AST cache invalidation"
# CMake's LLVM PCH producer is a C++ translation unit using -emit-pch.
# It must pass through to Clang; its dependents can still hit the object cache.
echo "Test 8: CMake-style PCH producer, consumer and object cache"
printf '\\n' > "$PCH_TEST_DIR/cmake_pch.hxx.cxx"
$CXX -O2 -Xclang -fno-pch-timestamp -Xclang -emit-pch \
    -Xclang -include -Xclang "$PCH_TEST_DIR/pch.hxx" -x c++ \
    -c "$PCH_TEST_DIR/cmake_pch.hxx.cxx" -o "$PCH_TEST_DIR/cmake_pch.hxx.pch"
test -s "$PCH_TEST_DIR/cmake_pch.hxx.pch" || {
    echo "FAIL: CMake-style PCH producer did not write a PCH"
    exit 1
}
cat > "$PCH_TEST_DIR/cmake_user.cc" <<'EOF'
int whp_cmake_probe() { return whp_pch_value(); }
EOF
compile_cmake_consumer() {
    $CXX -O2 -Xclang -include-pch -Xclang "$PCH_TEST_DIR/cmake_pch.hxx.pch" \
        -c "$PCH_TEST_DIR/cmake_user.cc" -o "$PCH_TEST_DIR/cmake_user.o"
}
compile_cmake_consumer
hits_before_reuse=$(pch_cache_hits)
rm -f "$PCH_TEST_DIR/cmake_user.o"
compile_cmake_consumer
hits_after_reuse=$(pch_cache_hits)
test "$hits_after_reuse" -gt "$hits_before_reuse" || {
    echo "FAIL: CMake-style PCH consumer did not hit the object cache"
    exit 1
}
echo "PASS: CMake-style PCH consumer cache hit"
