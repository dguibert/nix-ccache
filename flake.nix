{
  description = "A C/C++/Fortran compilation cache using recursive Nix";

  edition = 201909;

  inputs.nixpkgs.uri = "github:dguibert/nixpkgs/pu";

  outputs = { self, nixpkgs }: {

    overlay = final: prev: with final; {

      nix-ccache = nixCCacheFun final.stdenv.cc.cc;

      nixCCacheFun = compiler: final.runCommand "nix-ccache"
        { next = compiler;
          binutils = final.binutils;
          nix = final.nix;
          requiredSystemFeatures = [ "recursive-nix" ];
        }
        ''
          mkdir -p $out/bin

          for i in gcc g++ icc icpc; do
            if test -e $next/bin/$i; then
              substitute ${./cc-wrapper.sh} $out/bin/$i \
                --subst-var-by next $next \
                --subst-var-by program $i \
                --subst-var shell \
                --subst-var nix \
                --subst-var system \
                --subst-var out \
                --subst-var binutils
              chmod +x $out/bin/$i
            fi
          done

          ln -s $next/bin/cpp $out/bin/cpp
        '';

      nix-ccacheStdenv = final.overrideCC final.stdenv
        (final.wrapCC final.nix-ccache);

      nixFCacheFun = compiler: final.runCommand "nix-fcache"
        { next = compiler;
          binutils = final.binutils;
          nix = final.nix;
          requiredSystemFeatures = [ "recursive-nix" ];
        }
        ''
          mkdir -p $out/bin

          for i in gfortran ifort; do
            if test -e $next/bin/$i; then
              substitute ${./fc-wrapper.sh} $out/bin/$i \
                --subst-var-by next $next \
                --subst-var-by program $i \
                --subst-var shell \
                --subst-var nix \
                --subst-var system \
                --subst-var out \
                --subst-var binutils
              chmod +x $out/bin/$i
            fi
          done

          ln -s $next/bin/cpp $out/bin/cpp
        '';

      nix-fcache = nixFCacheFun final.gfortran;
    };

    testPkgs = import nixpkgs {
      system = "x86_64-linux";
      overlays =
        [ self.overlay
          (final: prev: {

            geeqie = prev.geeqie.overrideAttrs (attrs: {
              stdenv = final.nix-ccacheStdenv;
              requiredSystemFeatures = [ "recursive-nix" ];
            });

            nixUnstable = prev.nixUnstable.overrideAttrs (attrs: {
              stdenv = final.nix-ccacheStdenv;
              requiredSystemFeatures = [ "recursive-nix" ];
              doInstallCheck = false;
            });

            hello = prev.hello.overrideAttrs (attrs: {
              stdenv = final.nix-ccacheStdenv;
              requiredSystemFeatures = [ "recursive-nix" ];
            });

            patchelf-new = prev.patchelf.overrideAttrs (attrs: {
              stdenv = final.nix-ccacheStdenv;
              requiredSystemFeatures = [ "recursive-nix" ];
            });

            trivial = final.nix-ccacheStdenv.mkDerivation {
              name = "trivial";
              requiredSystemFeatures = [ "recursive-nix" ];
              buildCommand = ''
                set -x
                mkdir -p $out/bin
                $CXX -o hello.o -c ${./hello.cc} -DWHO='"World"' #-std=c++11
                $CXX -o $out/bin/hello hello.o
                $out/bin/hello
                set +x
              '';
            };

            trivial_f90 = final.nix-ccacheStdenv.mkDerivation {
              name = "trivial_f90";
              requiredSystemFeatures = [ "recursive-nix" ];
              buildInputs = [ final.nix-fcache ];
              buildCommand = ''
                mkdir -p $out/bin
                ''${FC:-gfortran} -o hello.o -c ${./hello.f90}
                ''${FC:-gfortran} -o $out/bin/hello hello.o
                $out/bin/hello
              '';
            };

            submodules_f90 = final.nix-ccacheStdenv.mkDerivation {
              name = "submodules_f90";
              requiredSystemFeatures = [ "recursive-nix" ];
              buildInputs = [ final.nix-fcache ];
              buildCommand = ''
                mkdir -p $out/bin
                ''${FC:-gfortran} -o submodule-math.o -c ${./submodule-math.F90}
                ''${FC:-gfortran} -o submodule-main.o -c ${./submodule-main.F90}
                ''${FC:-gfortran} -o $out/bin/hello submodule-main.o submodule-math.o
                $out/bin/hello
              '';
            };

            hdf5 = (prev.hdf5.override {
              stdenv = final.nix-ccacheStdenv;
            }).overrideAttrs (attrs: {
              requiredSystemFeatures = [ "recursive-nix" ];
            });

            hdf5-fortran = (prev.hdf5-fortran.override {
              stdenv = final.nix-ccacheStdenv;
              gfortran = final.nix-fcache;
            }).overrideAttrs (attrs: {
              requiredSystemFeatures = [ "recursive-nix" ];
            });

            openmpi = (prev.openmpi.override {
              stdenv = final.nix-ccacheStdenv;
              gfortran = final.nix-fcache;
            }).overrideAttrs (attrs: {
              requiredSystemFeatures = [ "recursive-nix" ];
            });


          })
        ];
    };

    checks.x86_64-linux.geeqie = self.testPkgs.geeqie;
    checks.x86_64-linux.hello = self.testPkgs.hello;
    checks.x86_64-linux.patchelf = self.testPkgs.patchelf-new;
    checks.x86_64-linux.trivial = self.testPkgs.trivial;
    checks.x86_64-linux.nixUnstable = self.testPkgs.nixUnstable;
    checks.x86_64-linux.trivial_f90 = self.testPkgs.trivial_f90;
    checks.x86_64-linux.submodules_f90 = self.testPkgs.submodules_f90;

    defaultPackage.x86_64-linux = self.testPkgs.nix-ccache;

  };
}
