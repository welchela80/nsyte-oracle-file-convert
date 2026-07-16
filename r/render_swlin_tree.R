# Headless renderer for the SWLIN hierarchy visualizations.
# Writes: out/swlin_tree.html (interactive collapsible tree),
#         out/swlin_dendrogram_<ROOT>.png, out/swlin_rollup.png
# Usage:  Rscript r/render_swlin_tree.R [ROOT]   (default ROOT = "25")

.libPaths(Sys.getenv("R_LIBS_USER"))
suppressPackageStartupMessages({
  library(DBI); library(dplyr); library(data.tree)
  library(collapsibleTree); library(htmlwidgets)
  library(igraph); library(ggraph); library(ggplot2)
})

ROOT <- if (length(commandArgs(TRUE)) >= 1) commandArgs(TRUE)[1] else "25"
out_dir <- file.path(dirname(sub("--file=", "", grep("--file=", commandArgs(), value = TRUE))), "out")
dir.create(out_dir, showWarnings = FALSE)

con <- dbConnect(RPostgres::Postgres(), host = "localhost", port = 5432,
                 dbname = "nmd", user = "nmd", password = "nmd")
h <- dbGetQuery(con, "
  SELECT swlin, parent, root, depth,
         array_to_string(path, '/') AS path_str,
         equipment_rows, maint_actions, nomenclature
  FROM canonical.swlin_hierarchy
  WHERE swlin !~ '^-'          -- drop the junk '-----' value
  ORDER BY swlin")
dbDisconnect(con)
cat(sprintf("%d nodes, %d roots, max depth %d\n",
            nrow(h), sum(is.na(h$parent)), max(h$depth)))

# ── interactive collapsible tree ──────────────────────────────────────────────
# Insert a synthetic first-character level so the super-root has ~30 children
# instead of 430 (SWLIN -> "2xx" -> "25" -> "255" -> ...).
# Leaves are labelled "<swlin> · <equipment nomenclature>"; full details in tooltips.
h$bucket  <- paste0(substr(h$root, 1, 1), "xx")
is_leaf   <- !(h$swlin %in% h$parent)
h$label   <- ifelse(is_leaf & !is.na(h$nomenclature),
                    paste0(h$swlin, " · ",
                           substr(gsub("/", "-", h$nomenclature), 1, 34)),
                    h$swlin)
h$path_lbl <- ifelse(grepl("/", h$path_str),
                     paste0(sub("/[^/]*$", "", h$path_str), "/", h$label),
                     h$label)
h$tooltip_html <- sprintf(
  "<b>%s</b>%s<br>equipment rows: %s<br>maintenance actions: %s",
  h$swlin,
  ifelse(is.na(h$nomenclature), "",
         paste0("<br><i>", htmltools::htmlEscape(h$nomenclature), "</i>")),
  format(as.numeric(h$equipment_rows), big.mark = ",", scientific = FALSE),
  format(as.numeric(h$maint_actions),  big.mark = ",", scientific = FALSE))
h$pathString <- paste("SWLIN", h$bucket, h$path_lbl, sep = "/")
tree <- as.Node(h)
# synthetic nodes (root + buckets) need the attribute too, or the widget rejects it
tree$Do(function(x) if (is.null(x$tooltip_html))
  x$tooltip_html <- paste0("<b>", x$name, "</b>"))
w <- collapsibleTree(tree, collapsed = TRUE, tooltip = TRUE,
                     tooltipHtml = "tooltip_html", fontSize = 12, zoomable = TRUE,
                     width = 1400, height = 900)
saveWidget(w, file.path(normalizePath(out_dir), "swlin_tree.html"),
           selfcontained = FALSE, libdir = "lib",
           title = "SWLIN hierarchy (nearest-ancestor tree)")
cat("wrote", file.path(out_dir, "swlin_tree.html"), "\n")

# ── static dendrogram of one subtree ─────────────────────────────────────────
sub <- h %>% filter(root == ROOT | startsWith(swlin, ROOT))
edges <- sub %>% filter(!is.na(parent), parent %in% sub$swlin) %>%
  select(from = parent, to = swlin)
g <- graph_from_data_frame(edges, vertices = sub %>%
       select(name = swlin, depth, equipment_rows, maint_actions))

p <- ggraph(g, layout = "dendrogram", circular = FALSE) +
  geom_edge_diagonal(colour = "grey70", alpha = 0.6) +
  geom_node_point(aes(size = maint_actions, colour = factor(depth))) +
  geom_node_text(aes(label = name, filter = maint_actions > 500 | depth <= 2),
                 size = 2.6, angle = 90, hjust = 1.1, vjust = 0.4) +
  scale_size_continuous(range = c(0.5, 8), labels = scales::comma) +
  labs(title    = sprintf("SWLIN subtree %s (nearest-ancestor hierarchy)", ROOT),
       subtitle = "node size = maintenance actions on that SWLIN; labels on depth <= 2 or > 500 actions",
       size = "maint actions", colour = "depth") +
  theme_void() +
  theme(plot.margin = margin(10, 10, 30, 10))
f <- file.path(out_dir, sprintf("swlin_dendrogram_%s.png", ROOT))
ggsave(f, p, width = 14, height = 8, dpi = 120, bg = "white")
cat("wrote", f, "\n")

# ── maintenance load by top-level group ──────────────────────────────────────
p2 <- h %>%
  group_by(root) %>%
  summarise(maint_actions = sum(maint_actions), .groups = "drop") %>%
  slice_max(maint_actions, n = 20) %>%
  ggplot(aes(x = reorder(root, maint_actions), y = maint_actions)) +
  geom_col(fill = "steelblue") +
  coord_flip() +
  scale_y_continuous(labels = scales::comma) +
  labs(title = "Maintenance actions by top-level SWLIN group (top 20)",
       x = "root SWLIN", y = "maintenance actions") +
  theme_minimal()
ggsave(file.path(out_dir, "swlin_rollup.png"), p2, width = 8, height = 6, dpi = 120, bg = "white")
cat("wrote", file.path(out_dir, "swlin_rollup.png"), "\n")
