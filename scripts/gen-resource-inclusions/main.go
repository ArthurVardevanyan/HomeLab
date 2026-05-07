package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

// skipKinds are non-Kubernetes / tooling-only kinds to ignore
var skipKinds = map[string]bool{
	"Kustomization": true,
	"Component":     true,
}

// skipGroups are API groups whose resources should never appear in inclusions
var skipGroups = map[string]bool{
	"packages.operators.coreos.com": true,
	"kustomize.config.k8s.io":       true,
}

type resource struct {
	APIVersion string `yaml:"apiVersion"`
	Kind       string `yaml:"kind"`
}

func apiGroup(apiVersion string) string {
	if idx := strings.Index(apiVersion, "/"); idx != -1 {
		return apiVersion[:idx]
	}
	return `""`
}

func buildInclusions(groupKinds map[string]map[string]bool) string {
	groups := make([]string, 0, len(groupKinds))
	for g := range groupKinds {
		groups = append(groups, g)
	}
	sort.Strings(groups)

	var sb strings.Builder
	sb.WriteString("  resourceInclusions: |\n")
	for _, group := range groups {
		kinds := make([]string, 0, len(groupKinds[group]))
		for k := range groupKinds[group] {
			kinds = append(kinds, k)
		}
		sort.Strings(kinds)

		sb.WriteString("    - apiGroups:\n")
		fmt.Fprintf(&sb, "      - %s\n", group)
		sb.WriteString("      clusters:\n")
		sb.WriteString("      - '*'\n")
		sb.WriteString("      kinds:\n")
		for _, kind := range kinds {
			fmt.Fprintf(&sb, "      - %s\n", kind)
		}
	}
	return sb.String()
}

// resourceInclusionsRe matches an existing resourceInclusions block (multiline string value)
// up to but not including the next top-level spec key or end of spec.
var resourceInclusionsRe = regexp.MustCompile(`(?m)^  resourceInclusions: \|[\s\S]*?(?:^  [a-zA-Z]|\z)`)

func updateFile(path, inclusions string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	content := string(data)

	// The replacement block should not consume the first char of the next key,
	// so we trim the trailing newline+nextKey captured by the lookahead workaround.
	replacement := inclusions
	// If existing block found, replace it; otherwise insert before resourceExclusions
	if resourceInclusionsRe.MatchString(content) {
		content = resourceInclusionsRe.ReplaceAllStringFunc(content, func(match string) string {
			// If the match consumed the start of the next key, preserve it
			if !strings.HasSuffix(match, "\n") {
				lastNL := strings.LastIndex(match, "\n  ")
				if lastNL != -1 {
					return replacement + match[lastNL+1:]
				}
			}
			return replacement
		})
	} else {
		// Insert before resourceExclusions
		content = strings.Replace(content, "  resourceExclusions:", replacement+"  resourceExclusions:", 1)
	}

	return os.WriteFile(path, []byte(content), 0o644)
}

func scanDirs(dirs []string) map[string]map[string]bool {
	groupKinds := map[string]map[string]bool{}
	for _, dir := range dirs {
		_ = filepath.WalkDir(dir, func(path string, d os.DirEntry, err error) error {
			if err != nil || d.IsDir() {
				return nil
			}
			ext := strings.ToLower(filepath.Ext(path))
			if ext != ".yaml" && ext != ".yml" {
				return nil
			}
			data, err := os.ReadFile(path)
			if err != nil {
				return nil
			}
			dec := yaml.NewDecoder(strings.NewReader(string(data)))
			for {
				var doc resource
				if err := dec.Decode(&doc); err != nil {
					break
				}
				if doc.Kind == "" || doc.APIVersion == "" {
					continue
				}
				if skipKinds[doc.Kind] {
					continue
				}
				group := apiGroup(doc.APIVersion)
				if skipGroups[group] {
					continue
				}
				if groupKinds[group] == nil {
					groupKinds[group] = map[string]bool{}
				}
				groupKinds[group][doc.Kind] = true
			}
			return nil
		})
	}
	return groupKinds
}

func main() {
	writeFile := flag.String("write", "", "Path to an ArgoCD CR YAML file to update resourceInclusions in-place")
	skipGroupsFlag := flag.String("skip-groups", "", "Comma-separated list of additional API groups to exclude (e.g. tekton.dev,triggers.tekton.dev)")
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "Usage: go run . [flags] <dir> [dir...]\n\n")
		fmt.Fprintf(os.Stderr, "Scans directories for Kubernetes YAML files and prints a resourceInclusions block.\n\n")
		flag.PrintDefaults()
	}
	flag.Parse()

	dirs := flag.Args()
	if len(dirs) == 0 {
		flag.Usage()
		os.Exit(1)
	}

	if *skipGroupsFlag != "" {
		for _, g := range strings.Split(*skipGroupsFlag, ",") {
			skipGroups[strings.TrimSpace(g)] = true
		}
	}

	// When invoked via `go run -C <dir> .` the process cwd is changed to <dir>
	// but the shell's PWD env var still reflects the user's original directory.
	// Resolve all paths relative to that so repo-root-relative paths work correctly.
	shellPWD := os.Getenv("PWD")
	resolvePath := func(p string) string {
		if filepath.IsAbs(p) || shellPWD == "" {
			return p
		}
		cwd, err := os.Getwd()
		if err != nil || shellPWD == cwd {
			return p
		}
		return filepath.Join(shellPWD, p)
	}

	resolvedDirs := make([]string, len(dirs))
	for i, d := range dirs {
		resolvedDirs[i] = resolvePath(d)
	}

	groupKinds := scanDirs(resolvedDirs)
	inclusions := buildInclusions(groupKinds)

	if *writeFile != "" {
		resolved := resolvePath(*writeFile)
		if err := updateFile(resolved, inclusions); err != nil {
			fmt.Fprintf(os.Stderr, "error updating %s: %v\n", resolved, err)
			os.Exit(1)
		}
		fmt.Printf("Updated %s\n", resolved)
		cmd := exec.Command("prettier", "--write", resolved)
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		if err := cmd.Run(); err != nil {
			fmt.Fprintf(os.Stderr, "warning: prettier failed: %v\n", err)
		}
	} else {
		fmt.Print(inclusions)
	}
}
