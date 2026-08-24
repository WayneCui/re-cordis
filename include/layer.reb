REBOL []

; ============================================================
; include/layer.reb — stack patch layers over an empty root (dsh-shaped).
; ============================================================

; Flatten patch layers (each layer = block of patch maps) and apply in order.
; Same semantics as dsh composeEntries: bundle ? profile ? home ? --patch.
compose-entry-layers: func [layers [block!] /local patch-list layer patch] [
    patch-list: copy []
    foreach layer layers [
        if block? layer [
            foreach patch layer [
                append patch-list patch
            ]
        ]
    ]
    apply-entry-patches copy [] patch-list
]
