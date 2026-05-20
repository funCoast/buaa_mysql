# cd /workspace/mysql-server-8.4/build

# cmake --build . --target mysqld -- -j"$(nproc)"
# cp runtime_output_directory/mysqld /workspace/mysql_install/bin/

JOBS=${JOBS:-"$(nproc)"}

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"
build_dir="$repo_root/build"
install_dir="/workspace/mysql_install"   
mysqld_bin="$build_dir/runtime_output_directory/mysqld"

cmake --build "$build_dir" --target mysqld -- -j"$JOBS"
install -m 0755 "$mysqld_bin" "$install_dir/bin/mysqld"
