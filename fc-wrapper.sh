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

case "@program@$source" in
    gfortran*.f90)
        ext=f90;;
    gfortran*.F90)
        ext=f90;;
    ifort*.f90)
        ext=i90;;
    ifort*.F90)
        ext=i90;;
    *.c)
        ext=i;;
    *.cxx|*.cpp)
        ext=ii;;
    *)
        exit 11 # unimplemented extension
esac

#echo "NIX-FCACHE: $@" >&2

#echo "preprocessing to $dest.$ext..." >&2

compiling_module=false

#set -x
old_IFS=$IFS
case @program@ in
    gfortran)

    # Find .h included via 'include "header.h"' (NB use " and ')
    # gfortran is not able to recursively include these files
    if grep -i "[^#]include\s*[\"']" "$source" >/dev/null; then
      echo "$0: warning: include statements in source are not handled" >&2
      exec @next@/bin/@program@ "$@"
      #echo "==> REPLACE include $source"
      #sed -i.orig -e "s:\s*[^#]include\s*[\"']\(.*\)[\"']:#include \"\1\":" "$source"
    fi

    @next@/bin/@program@ -o "$dest.$ext" -E -cpp "$source" "${cppFlags[@]}"

    # FIXME: could call recursively the sed command, but it's simpler to fallback to directly call the compiler
    if grep -i "[^#]include\s*[\"']" "$dest.$ext" >/dev/null; then
      # Replace them with #include
      echo "$0: warning: include statements in source are not handled" >&2
      exec @next@/bin/@program@ "$@"
    fi

    # INFO generate the module file
    modules=
    needed_modules=
    while IFS=: read -r targets deps
    do
      outputs=(${targets[@]})
      dependencies=(${deps[@]})
      for target in ${outputs}; do
        if [[ $target =~ \.mod$ ]]; then
            modules+=" $target"
        fi
      done
      IFS=' '
      for dep in ${deps}; do
          if [[ $dep =~ \.mod$ ]]; then
              needed_modules+=" $dep"
              compiling_module=true
          fi
      done
    done < <(@next@/bin/@program@ -cpp -MM "$dest.$ext" "${cppFlags[@]}" | sed -z -e 's:\\\s*\n::g' -e 's:\n\n:\n:g') # remove \ and empty lines

    ;;
    ifort)
    # INFO generate the module file
    modules=
    needed_modules=
    while IFS=: read -r targets deps
    do
      outputs=(${targets[@]})
      dependencies=(${deps[@]})
      for target in ${outputs}; do
        if [[ $target =~ \.mod$ ]]; then
            modules+=" $target"
        fi
      done
      IFS=' '
      for dep in ${deps}; do
          if [[ $dep =~ \.mod$ ]]; then
              needed_modules+=" $dep"
              compiling_module=true
          fi
      done
    done < <(@next@/bin/@program@ -fpp -syntax-only -gen-dep "$source" "${cppFlags[@]}" | sed -z -e 's:\\\s*\n::g' -e 's:\n\n:\n:g') # remove \ and empty lines
    mv $(basename $(basename $source .f90) .F90).$ext "$dest.$ext"
    ;;
    *)
    echo "Undefined compiler @program@" >&2
    exit 10
    ;;
esac
IFS=$old_IFS


#echo "compiling to $dest..."

escapedArgs='"-o" "${placeholder "out"}" "-c" '$(readlink -f "$dest.$ext")' '

# populate an included folder with the needed module files
# iits unique folder but same end name for multiple parallel compilations
# it does not change the hash
if $compiling_module; then
  tmp_mod=$(mktemp -d mod_XXX)/modules_path
  mkdir $tmp_mod
  for mod in $needed_modules; do
      # TODO find modules in include paths as well
      cp -v $mod $tmp_mod
  done
  modules_d="$(readlink -f $tmp_mod)"
  escapedArgs+='"-I" '$modules_d' '
fi
## FIXME: add any store paths mentioned in the arguments (e.g. -B
## flags) to the input closure, or filter them?
args_B="$(ls -d @next@/libexec/gcc/x86_64-unknown-linux-gnu/* 2>/dev/null || echo "")"
if test -n "${args_B}"; then
  args_B="${args_B:+"-B${args_B}"}"
  escapedArgs=''$escapedArgs' "'$args_B'" '
fi

for arg in "${compileFlags[@]}"; do
    escapedArgs+='"'
    escapedArgs+="$arg" # FIXME: escape
    escapedArgs+='" '
done

#echo "FINAL: $escapedArgs"

@nix@/bin/nix-build --quiet -o "$dest.link" -E '(
  derivation {
    name = "fc";
    system = "@system@";
    builder = builtins.storePath "@next@/bin/@program@";
    extra = builtins.storePath "@binutils@";
    args = [ '"$escapedArgs"' "-B@binutils@/bin" ]; # FIXME
  }
)' > /dev/null

cp "$dest.link" "$dest"
rm -f "$dest.$ext" "$dest.link"
if $compiling_module; then
  rm -rf "$tmp_mod"
fi

exit 0
