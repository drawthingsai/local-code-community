"""LocalCode embedded Python startup policy."""

try:
    import mimetypes as _localcode_mimetypes
except Exception:
    pass
else:
    # iOS has no Unix /etc MIME database. Keep MIME lookup deterministic and
    # avoid probing host-specific locations such as /etc/apache2/mime.types.
    _localcode_mimetypes.knownfiles = []
