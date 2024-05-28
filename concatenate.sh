#!/bin/bash

# Check if a directory is provided as an argument
if [ -z "$1" ]; then
  echo "Usage: $0 <directory> (output file)"
  exit 1
fi

# Define the target directory
target_dir="${1%/}"
default_target="${target_dir}.txt"

# Define the output file
output_file="${2:-$default_target}"

# Create or empty the output file
cat > "$output_file" << EOF
# concatenation of $target_dir/ - all the files from $target_dir/
# have been included in this single file, each preceded by a
# descriptive preamble that includes the filename in the opening
# tag.
EOF

# Find all files in the target directory and its subdirectories
find "$target_dir" -type f | while read -r file; do
  # Append a preamble with a spot for describing the file
  cat << EOF >> "$output_file"
<preamble file: $file>

</preamble>
<file_content file: $file>
EOF
  # Append the contents of the file to the output file
  cat "$file" >> "$output_file"
  # Add newline if absent
  if [ -n "$(tail -c 1 "$file" | tr -d '\n')" ]; then
    echo "" >> "$output_file"
  fi
  # Add the closing tag
  echo "</file_content file: $file>" >> "$output_file"
done

echo "Concatenation complete. Output file: $output_file"

