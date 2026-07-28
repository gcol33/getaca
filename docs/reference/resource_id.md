# Identify a resource

A resource is identified by the triple package / name / version, never
by name alone. Callers rarely build these by hand; the registry supplies
the package and the resolution policy supplies the version.

## Usage

``` r
resource_id(package, name, version)
```

## Arguments

- package:

  Declaring package name.

- name:

  Resource name, as declared in the registry.

- version:

  Resource version string.

## Value

An object of class `getaca_id`.

## Examples

``` r
resource_id("yourpkg", "backbone", "2026.1")
```
