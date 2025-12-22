import re
import os
import subprocess

# Configuration
# Determine the absolute path to the script
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
# The repo root is 3 levels up from kubernetes/renovate/scripts/
ROOT_DIR = os.path.abspath(os.path.join(SCRIPT_DIR, "../../.."))

SKIP_DIRS = {".git", ".venv", "venv", "__pycache__", "node_modules", ".terraform", ".history"}
# Standard Kubernetes workloads where Renovate automatically detects 'image:'
STANDARD_K8S_KINDS = {
    "Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob", "Pod",
    "ReplicaSet", "ReplicationController"
}
# Directories to scan
SCAN_EXTENSIONS = {'.yaml', '.yml', '.json'}

# Regex patterns
# Matches 'image: value' or '  image: value'
IMAGE_PATTERN = re.compile(r'^\s*image:\s*["\']?([^\s"\']+)["\']?')
# Matches 'somethingImage: value' or 'operandImage: value' - case insensitive
KEY_VALUE_IMAGE_PATTERN = re.compile(r'^\s*[\w\-\.]*image[\w\-\.]*:\s*["\']?([^\s"\']+)["\']?', re.IGNORECASE)
FROM_PATTERN = re.compile(r'^FROM\s+([^\s]+)')
RENOVATE_COMMENT_PATTERN = re.compile(r'#\s*renovate:')
KIND_PATTERN = re.compile(r'^kind:\s*(\w+)')
SEPARATOR_PATTERN = re.compile(r'^---')

def is_dockerfile(filename):
    return "Dockerfile" in filename or "Containerfile" in filename

def get_relative_path(filepath):
    return os.path.relpath(filepath, ROOT_DIR)

def audit_images():
    managed_images = []
    unmanaged_images = []

    for root, dirs, files in os.walk(ROOT_DIR):
        # Skip ignored directories
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]

        for file in files:
            filepath = os.path.join(root, file)
            rel_path = get_relative_path(filepath)

            if is_dockerfile(file):
                process_dockerfile(filepath, rel_path, managed_images, unmanaged_images)
            elif file.endswith(tuple(SCAN_EXTENSIONS)):
                process_yaml(filepath, rel_path, managed_images, unmanaged_images)

    # Generate Report
    report_lines = []
    report_lines.append("# Renovate Image Audit")

    # Deduplicate
    unique_managed = sorted(list(set(item['image'] for item in managed_images)))
    unique_unmanaged = sorted(list(set(item['image'] for item in unmanaged_images)))

    report_lines.append(f"\n**Total Unique Managed:** {len(unique_managed)}")
    report_lines.append(f"**Total Unique Unmanaged:** {len(unique_unmanaged)}")

    report_lines.append("\n## Unmanaged Images (Potential Gaps)")
    report_lines.append("These images were found in files but do not appear to be managed by Renovate (no `# renovate:` comment and not a standard K8s workload).")
    report_lines.append("\n| Image |")
    report_lines.append("|---|")
    for image in unique_unmanaged:
        report_lines.append(f"| `{image}` |")

    report_lines.append("\n## Managed Images")
    report_lines.append("<details><summary>Click to expand</summary>\n")
    report_lines.append("| Image |")
    report_lines.append("|---|")
    for image in unique_managed:
        report_lines.append(f"| `{image}` |")
    report_lines.append("\n</details>")

    # Print to console
    print(f"Found {len(unique_managed)} unique managed and {len(unique_unmanaged)} unique unmanaged images.")

    # Update README
    readme_path = os.path.join(ROOT_DIR, "kubernetes/renovate/README.md")
    update_readme(readme_path, "\n".join(report_lines))

def process_dockerfile(filepath, rel_path, managed, unmanaged):
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            lines = f.readlines()
    except Exception:
        return

    for i, line in enumerate(lines):
        match = FROM_PATTERN.match(line)
        if match:
            image = match.group(1)
            # Dockerfiles are implicitly managed
            managed.append({
                "file": rel_path,
                "line": i + 1,
                "image": image,
                "source": "Dockerfile"
            })

def process_yaml(filepath, rel_path, managed, unmanaged):
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            lines = f.readlines()
    except Exception:
        return

    current_kind = "Unknown"

    for i, line in enumerate(lines):
        line_content = line.strip()

        # Track K8s Kind
        kind_match = KIND_PATTERN.match(line_content)
        if kind_match:
            current_kind = kind_match.group(1)
            continue

        if SEPARATOR_PATTERN.match(line_content):
            current_kind = "Unknown"
            continue

        # Check for image definition
        # We look for 'image:' only
        image_match = IMAGE_PATTERN.match(line_content)
        if image_match:
            image = image_match.group(1)

            # Filter out variables and booleans
            if "{{" in image or "$(" in image or image.lower() in ["true", "false", "yes", "no", "always", "never", "ifnotpresent"]:
                continue

            # Check for explicit Renovate comment
            has_comment = False
            # Check current line for comment
            if RENOVATE_COMMENT_PATTERN.search(lines[i]):
                has_comment = True
            # Check previous line for comment
            elif i > 0 and RENOVATE_COMMENT_PATTERN.search(lines[i-1]):
                has_comment = True

            if has_comment:
                managed.append({
                    "file": rel_path,
                    "line": i + 1,
                    "image": image,
                    "source": "Explicit Comment"
                })
            else:
                # Everything else is considered unmanaged if it lacks a comment
                unmanaged.append({
                    "file": rel_path,
                    "line": i + 1,
                    "image": image,
                    "kind": current_kind
                })

def update_readme(readme_path, content):
    try:
        with open(readme_path, 'r', encoding='utf-8') as f:
            original_content = f.read()

        # Split at the "## Image Audit" section if it exists, or append
        if "## Image Audit" in original_content:
            pre_content = original_content.split("## Image Audit")[0]
            new_content = pre_content + "\n" + content.replace("# Renovate Image Audit", "## Image Audit")
        else:
            new_content = original_content + "\n\n" + content.replace("# Renovate Image Audit", "## Image Audit")

        with open(readme_path, 'w', encoding='utf-8') as f:
            f.write(new_content)
        print(f"Updated {readme_path}")

        # Run prettier
        try:
            subprocess.run(["prettier", "--write", readme_path], check=True, capture_output=True)
            print(f"Formatted {readme_path} with prettier")
        except subprocess.CalledProcessError as e:
            print(f"Failed to run prettier: {e}")
        except FileNotFoundError:
            print("Prettier not found, skipping formatting")

    except Exception as e:
        print(f"Failed to update README: {e}")

if __name__ == "__main__":
    audit_images()
