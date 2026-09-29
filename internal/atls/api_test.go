package atls_test

import (
	"encoding/json"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

const cmcModule = "github.com/Fraunhofer-AISEC/cmc"

// TestExportedAPIHasNoCMCType lists the exported identifiers of package atls and checks that none
// of their signatures references a CMC type.
func TestExportedAPIHasNoCMCType(t *testing.T) {
	fset := token.NewFileSet()
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	checked := 0
	for _, name := range files {
		if strings.HasSuffix(name, "_test.go") {
			continue
		}
		f, err := parser.ParseFile(fset, name, nil, parser.SkipObjectResolution)
		if err != nil {
			t.Fatal(err)
		}
		cmcAliases := map[string]string{}
		for _, imp := range f.Imports {
			path, _ := strconv.Unquote(imp.Path.Value)
			if !strings.HasPrefix(path, cmcModule) {
				continue
			}
			alias := filepath.Base(path)
			if imp.Name != nil {
				alias = imp.Name.Name
			}
			cmcAliases[alias] = path
		}
		report := func(where string, n ast.Node) {
			checked++
			ast.Inspect(n, func(n ast.Node) bool {
				if sel, ok := n.(*ast.SelectorExpr); ok {
					if id, ok := sel.X.(*ast.Ident); ok {
						if path, ok := cmcAliases[id.Name]; ok {
							t.Errorf("%s: exported %s references %s.%s", fset.Position(sel.Pos()), where, path, sel.Sel.Name)
						}
					}
				}
				return true
			})
		}
		for _, decl := range f.Decls {
			switch d := decl.(type) {
			case *ast.FuncDecl:
				if !d.Name.IsExported() {
					continue
				}
				if d.Recv != nil && !exportedRecv(d.Recv) {
					continue
				}
				report("func "+d.Name.Name, d.Type)
				if d.Recv != nil {
					report("method "+d.Name.Name, d.Recv)
				}
			case *ast.GenDecl:
				for _, spec := range d.Specs {
					switch s := spec.(type) {
					case *ast.TypeSpec:
						if !s.Name.IsExported() {
							continue
						}
						if st, ok := s.Type.(*ast.StructType); ok {
							for _, field := range st.Fields.List {
								if exportedField(field) {
									report("field of "+s.Name.Name, field.Type)
								}
							}
							continue
						}
						if it, ok := s.Type.(*ast.InterfaceType); ok {
							report("interface "+s.Name.Name, it)
							continue
						}
						report("type "+s.Name.Name, s.Type)
					case *ast.ValueSpec:
						for _, n := range s.Names {
							if n.IsExported() {
								if s.Type != nil {
									report("value "+n.Name, s.Type)
								}
								for _, v := range s.Values {
									report("value "+n.Name, v)
								}
							}
						}
					}
				}
			}
		}
	}
	if checked == 0 {
		t.Fatal("no exported declarations inspected")
	}
}

func exportedRecv(fl *ast.FieldList) bool {
	typ := fl.List[0].Type
	if star, ok := typ.(*ast.StarExpr); ok {
		typ = star.X
	}
	id, ok := typ.(*ast.Ident)
	return ok && id.IsExported()
}

func exportedField(f *ast.Field) bool {
	if len(f.Names) == 0 { // embedded
		typ := f.Type
		if star, ok := typ.(*ast.StarExpr); ok {
			typ = star.X
		}
		switch x := typ.(type) {
		case *ast.Ident:
			return x.IsExported()
		case *ast.SelectorExpr:
			return x.Sel.IsExported()
		}
		return false
	}
	for _, n := range f.Names {
		if n.IsExported() {
			return true
		}
	}
	return false
}

// TestPinnedVersion: go.mod requires CMC v0.9.15 and does not replace it.
func TestPinnedVersion(t *testing.T) {
	out, err := exec.Command("go", "mod", "edit", "-json", filepath.Join(moduleRoot(t), "go.mod")).Output()
	if err != nil {
		t.Fatal(err)
	}
	var mod struct {
		Require []struct{ Path, Version string }
		Replace []struct{ Old struct{ Path string } }
	}
	if err := json.Unmarshal(out, &mod); err != nil {
		t.Fatal(err)
	}
	found := false
	for _, r := range mod.Require {
		if r.Path == cmcModule {
			found = r.Version == "v0.9.15"
			if !found {
				t.Fatalf("go.mod requires %s %s, want v0.9.15", cmcModule, r.Version)
			}
		}
	}
	if !found {
		t.Fatalf("go.mod does not require %s", cmcModule)
	}
	for _, r := range mod.Replace {
		if strings.HasPrefix(r.Old.Path, cmcModule) {
			t.Fatalf("go.mod replaces %s", r.Old.Path)
		}
	}
}

func moduleRoot(t *testing.T) string {
	t.Helper()
	out, err := exec.Command("go", "list", "-m", "-f", "{{.Dir}}").Output()
	if err != nil {
		t.Fatal(err)
	}
	return strings.TrimSpace(string(out))
}

// probe compiles (or runs) a throwaway package outside internal/atls, added through a build
// overlay so the source tree is not touched, and returns the go command's output.
func probe(t *testing.T, verb, src string) (string, error) {
	t.Helper()
	root := moduleRoot(t)
	dir := t.TempDir()
	file := filepath.Join(dir, "probe.go")
	if err := os.WriteFile(file, []byte(src), 0o600); err != nil {
		t.Fatal(err)
	}
	virtual := filepath.Join(root, "internal", "zzatlsprobe", "probe.go")
	overlay, _ := json.Marshal(map[string]map[string]string{"Replace": {virtual: file}})
	overlayFile := filepath.Join(dir, "overlay.json")
	if err := os.WriteFile(overlayFile, overlay, 0o600); err != nil {
		t.Fatal(err)
	}
	args := []string{verb, "-overlay", overlayFile}
	if verb == "build" {
		args = append(args, "-o", os.DevNull)
	}
	cmd := exec.Command("go", append(args, "./internal/zzatlsprobe")...)
	cmd.Dir = root
	out, err := cmd.CombinedOutput()
	return string(out), err
}

const modulePath = "github.com/eclipse-xfsc/facis-zero-trust-demonstrator"

// 5.12 A non-test package cannot select the in-process backend: the hook package is internal to
// internal/atls, the Config field is unexported, and atlstest refuses to run outside tests.
func TestInProcessBackendUnreachableFromProduction(t *testing.T) {
	if testing.Short() {
		t.Skip("compiles probe packages")
	}
	t.Run("hook package", func(t *testing.T) {
		out, err := probe(t, "build", `package probe

import _ "`+modulePath+`/internal/atls/internal/testhook"
`)
		if err == nil || !strings.Contains(out, "use of internal package") {
			t.Fatalf("importing the hook package from outside internal/atls compiled: %v\n%s", err, out)
		}
	})
	t.Run("config field", func(t *testing.T) {
		out, err := probe(t, "build", `package probe

import "`+modulePath+`/internal/atls"

var _ = atls.Config{inProcess: nil}
`)
		if err == nil || !strings.Contains(out, "inProcess") {
			t.Fatalf("setting the in-process field from outside internal/atls compiled: %v\n%s", err, out)
		}
	})
	t.Run("atlstest outside tests", func(t *testing.T) {
		out, err := probe(t, "run", `package main

import (
	"`+modulePath+`/internal/atls"
	"`+modulePath+`/internal/atls/atlstest"
)

func main() { _ = atlstest.ForceVerdict(atls.Config{}, "success") }
`)
		if err == nil || !strings.Contains(out, "test-only package used outside a test binary") {
			t.Fatalf("atlstest ran outside a test binary: %v\n%s", err, out)
		}
	})
}
