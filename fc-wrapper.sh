#! @shell@
set -eu

if [[ ! -v NIX_REMOTE ]]; then
    echo "$0: warning: recursive Nix is disabled" >&2
    exec @next@/bin/@program@ "$@"
fi

isCompilation=
cppFlags=()
compileFlags=()
sources=()
dest=

args=("$@")

for ((n = 0; n < $#; n++)); do
    arg="${args[$n]}"

    if [[ $arg = -c ]]; then
        isCompilation=1
    elif [[ $arg = -o ]]; then
        : $((n++))
        dest="${args[$n]}"
    elif [[ $arg = --param ]]; then
        : $((n++))
        cppFlags+=("$arg" "${args[$n]}")
        compileFlags+=("$arg" "${args[$n]}")
    elif [[ $arg = -idirafter || $arg = -I || $arg = -isystem || $arg = -include || $arg = -MF ]]; then
        : $((n++))
        cppFlags+=("$arg" "${args[$n]}")
    elif [[ $arg =~ ^-D.* || $arg =~ ^-I.* ]]; then
        cppFlags+=("$arg")
    elif [[ $arg =~ -J ]]; then
        exit 10 # unimplemented: handle fortran module outpath
    elif [[ ! $arg =~ ^- ]]; then
        sources+=("$arg")
    else
        cppFlags+=("$arg")
        compileFlags+=("$arg")
    fi
done

if [[ ! $isCompilation || ${#sources[*]} != 1 || ${sources[0]} =~ conftest ]]; then
    #echo "SKIP: ${sources[@]}" >&2
    exec @next@/bin/@program@ "$@"
fi

source="${sources[0]}"

if [[ -z $dest ]]; then
    dest="$(basename "$source" .c).o" # FIXME
fi

case $source in
    *.f90)
        ext=f90;;
    *.F90)
        ext=f90;;
    *.c)
        ext=i;;
    *.cxx|*.cpp)
        ext=ii;;
    *)
        exit 11 # unimplemented extension
esac

echo "NIX-CCACHE: $@" >&2

echo "preprocessing to $dest.$ext..." >&2

escapedArgs='"-o" "${placeholder "out"}" "-c" '$(readlink -f "$dest.$ext")' '

compiling_module=false

case @program@ in
    gfortran)
    #gfortran: error: gfortran does not support -E without -cpp
    @next@/bin/@program@ -o "$dest.$ext" -E -cpp "$source" "${cppFlags[@]}"
    # INFO generate the module file
    deps_line=$(@next@/bin/@program@ -cpp -MM "$dest.$ext" "${cppFlags[@]}")
    deps_line=${deps_line//[$'\\\n']}
    IFS=':'
    deps=( $deps_line )
    outputs=${deps[0]}
    dependencies=${deps[1]}
    #echo $outputs
    modules=
    IFS=' '
    for output in $outputs; do
        echo $output
        if [[ $output =~ \.mod$ ]]; then
            modules+=" $output"
        fi
    done
    needed_modules=
    for dep in $dependencies; do
        if [[ $dep =~ \.mod$ ]]; then
            needed_modules+=" $dep"
            compiling_module=true
        fi
    done
    ;;
    *)
    echo "Undefined compiler @program@" >&2
    exit 10
    ;;
esac


echo "compiling to $dest..."
#escapedArgs='"-o" "${placeholder "out"}" "-c" '$(readlink -f "$dest.$ext")' '

# unique folder but same end name for multiple parallel compilations
# it does not change the hash
tmp_mod=$(mktemp -d mod_XXX)/modules_path
mkdir $tmp_mod
if $compiling_module; then
    for mod in $needed_modules; do
        # TODO find modules in include paths as well
        cp $mod $tmp_mod
    done
fi
modules_d="$(readlink -f $tmp_mod)"
escapedArgs+='"-I" '$modules_d' '

for arg in "${compileFlags[@]}"; do
    escapedArgs+='"'
    escapedArgs+="$arg" # FIXME: escape
    escapedArgs+='" '
done

echo "FINAL: $escapedArgs"


# FIXME: add any store paths mentioned in the arguments (e.g. -B
# flags) to the input closure, or filter them?

@nix@/bin/nix-build --verbose -o "$dest.link" -E '(
  derivation {
    name = "fc";
    system = "@system@";
    builder = builtins.storePath "@next@/bin/@program@";
    extra = builtins.storePath "@binutils@";
    args = [ '"$escapedArgs"' "-B@next@/libexec/gcc/x86_64-unknown-linux-gnu/8.3.0/" "-B@binutils@/bin" ]; # FIXME
  }
)' > /dev/null

cp "$dest.link" "$dest"
rm -f "$dest.$ext" "$dest.link"
rm -rf "$tmp_mod"

exit 0
