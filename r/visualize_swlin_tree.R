# Visualize canonical.swlin_hierarchy (SWLIN nearest-ancestor / longest-prefix tree)
#
# Run in RStudio. First install the packages once:
#   install.packages(c("DBI", "RPostgres", "dplyr", "data.tree",
#                      "collapsibleTree", "igraph", "ggraph", "ggplot2"))
#
# Produces:
#   1. An interactive collapsible tree of the whole hierarchy (RStudio Viewer pane).
#      4,727 nodes — start collapsed at the roots and click to expand.
#   2. A static dendrogram of ONE subtree (set ROOT below), sized by maintenance load.
#   3. A bar chart of maintenance actions rolled up to the top-level groups.

library(DBI)
library(dplyr)
library(data.tree)
library(collapsibleTree)
library(igraph)
library(ggraph)
library(ggplot2)

# ── connection ────────────────────────────────────────────────────────────────
# Postgres from docker-compose (host networking). If RStudio runs on Windows and
# the DB is in WSL2, "localhost" normally forwards; otherwise use the WSL IP.
con <- dbConnect(
  RPostgres::Postgres(),
  host = "localhost", port = 5432,
  dbname = "nmd", user = "nmd", password = "nmd"
)

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

# ── 1. interactive collapsible tree (whole hierarchy) ─────────────────────────
# One synthetic super-root ("SWLIN") plus a first-character bucket level
# ("2xx") so the 430 real roots don't all fan out of one node at once.
# Leaves are labelled "<swlin> · <equipment nomenclature>"; details in tooltips.
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

collapsibleTree(
  tree,
  collapsed   = TRUE,
  tooltip     = TRUE,
  tooltipHtml = "tooltip_html",
  fontSize    = 12,
  zoomable    = TRUE
)
# (renders in the Viewer pane; use Export > Save as Web Page to keep it)

# ── 2. static dendrogram of one subtree ──────────────────────────────────────
ROOT <- "25"   # <- pick any root/prefix: "255", "437", "51", "58", ...

sub <- h %>% filter(root == ROOT | startsWith(swlin, ROOT))
edges <- sub %>% filter(!is.na(parent), parent %in% sub$swlin) %>%
  select(from = parent, to = swlin)
g <- graph_from_data_frame(edges, vertices = sub %>%
       select(name = swlin, depth, equipment_rows, maint_actions))

ggraph(g, layout = "dendrogram", circular = FALSE) +
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

# ── 3. maintenance load rolled up to top-level groups ────────────────────────
h %>%
  group_by(root) %>%
  summarise(maint_actions = sum(maint_actions),
            swlins = n(), .groups = "drop") %>%
  slice_max(maint_actions, n = 20) %>%
  ggplot(aes(x = reorder(root, maint_actions), y = maint_actions)) +
  geom_col(fill = "steelblue") +
  coord_flip() +
  scale_y_continuous(labels = scales::comma) +
  labs(title = "Maintenance actions by top-level SWLIN group (top 20)",
       x = "root SWLIN", y = "maintenance actions") +
  theme_minimal()
