#############################################################
#Thomas Lamot, 2022

#Part of extract functions are derived from BactMAP (github.com/vrrenske/bactmap), van Raaphorst et al 2020

#############################################################

#Dependencies: janitor, tidyverse, purrr, sf

#Tidyverse packages & sf package need to be loaded before running these functions:
library(tidyverse)
library(sf)

#############################################################

#functions:

unnest_cell_meshes <- function(celllist, mesh) {
  celllist |>
    rowwise() |>
    filter(length({{mesh}}) >= 4) |>
    mutate(mesh = list(tidy_oufti_mesh({{mesh}}))) |>
    unnest({{mesh}}) -> meshes
  return(meshes)
}

tidy_oufti_mesh <- function(mesh) {
  as_tibble(mesh) |>
    rename(x0 = 1, y0 = 2, x1 = 3, y1 = 4) |>
    mutate(
        num = 0:(nrow(mesh) - 1)
      ) -> meshes
  return(meshes)
}

extract_oufti_celllist <- function(oufti_list) {
  purrr::map_dfr(
    oufti_list$cellList[[2]], .id = "frame",\(x){
      tibble(x) |> 
        unnest(cols = c(x)) |> 
        t() |>
        tibble()}) |> 
    rename(cell = 2) |>
    rowwise() |> 
    mutate(cell =cell[[1]]) |> 
    group_by(frame) |>
    summarise(cell = list(cell))  -> cellid

  purrr::map_dfr(
    oufti_list$cellList[[1]], .id = "frame",\(x){
      tibble(x) |> 
        unnest(cols = c(x)) |> 
        t() |>
        tibble()}) |> 
    rename(celldata = 2) |>
    rowwise() |> 
    mutate(celldata =list(celldata[[1]])) |>
    group_by(frame) |>
    summarise(celldata = list(celldata)) |>
    inner_join(cellid, by = c("frame" = "frame")) |>
    unnest_longer(c(celldata, cell)) |>
    unnest_wider(celldata) |>
    mutate(across(where(\(x) length(dim(x)) == 2 && dim(x)[2] == 1), \(x) c(x))) |>
    rowwise() |>
    mutate(box = list(st_box(bot = box[,2], height = box[,4], left = box[,1], width = box[,3]))) |> 
    select(-model)-> cell_list

  cell_list |>
    select(frame, cell, mesh) |> 
    unnest_cell_meshes(mesh) |> 
    get_cell_max_length_and_width(x0, y0, x1, y1, c(cell, frame)) |> 
    pivot_xy_longer(c(x0, x1, y0, y1), num, n) |> 
    summarise(
      mesh = list(st_polygon_autoclose(x, y)),
      max.length = mean(max.length),
      max.width = mean(max.width)) -> meshes

    cell_list |> 
    select(-c(mesh)) |>
      inner_join(meshes, by = c("frame" = "frame", "cell" = "cell")) |>
      st_sf(sf_column_name = "mesh") |>
      mutate(frame = as.integer(frame)) -> cell_list

  return(cell_list)
}


get_cell_max_length_and_width <- function(meshlist, x0, y0, x1, y1, .group) {
  meshlist |>
    group_by(across({{.group}})) |>
    mutate(
      xdist = {{x0}} - {{x1}},
      ydist = {{y0}} - {{y1}},
      widths = polar_distance(xdist, ydist),
      max.width = max(widths),
      xdistL0 = {{x0}} - lag({{x0}}, default = first({{x0}})),
      ydistL0 = {{y0}} - lag({{y0}}, default = first({{y0}})),
      distL0 = polar_distance(xdistL0, ydistL0),
      angL0 = polar_angle(ydistL0, xdistL0),
      rn = row_number(),
      n = n(),
      angd = if_else(
        rn == n,
        polar_angle(lag(ydist), lag(xdist)),
        polar_angle(ydist, xdist))
      ) |> 
    rowwise() |>
    mutate(
      anglength = if_else(
        rn == n,
        angle_from_vertical(abs(angL0), abs(angd)),
        angle_from_horizontal(abs(angL0), abs(angd))),
      steplength = if_else(
        rn == 1,
        0,
        sin(anglength) * distL0)) |>
    group_by(across({{.group}}))  |>
    mutate(
      length = cumsum(steplength),
      max.length = sum(steplength)) |>
      select(-c(xdist, ydist, xdistL0, ydistL0, distL0, angL0, angd, anglength, steplength, length)) -> meshlist
  return(meshlist)
}


center_and_rotate_meshes <- function(meshlist, x, y, .group) {
  meshlist |>
    group_by(across({{.group}}))  |>
    mutate(cell_polygon = list(st_polygon_autoclose(x = {{x}}, y = {{y}})),
           bounding_box_angle_centroid = list(get_minimum_bounding_box_centroid_and_angle({{x}}, {{y}}))) |>
    rowwise() |>
    mutate(
           cell_centroid = list(sf::st_centroid(cell_polygon)),
           area = sf::st_area(cell_polygon),
           bounding_box_centroid = list(bounding_box_angle_centroid[["centroid"]]),
           angle = (180 - bounding_box_angle_centroid[["angle"]]) * pi / 180,
           x_mid = bounding_box_centroid[1],
           y_mid = bounding_box_centroid[2],
           x_centered = {{x}} - x_mid,
           y_centered = {{y}} - y_mid) |>
    group_by(across({{.group}}))  |>
    mutate(
           is_positive_y_rotation = if_else(rotate(x_centered, y_centered, angle)[["y"]][[1]] > 0, TRUE, FALSE),
           angle = if_else(
             is_positive_y_rotation,
             angle + pi,
             angle),
           x_rotated = rotate(x_centered, y_centered, angle)[["x"]],
           y_rotated = rotate(x_centered, y_centered, angle)[["y"]]) |>
           select(-c(is_positive_y_rotation, cell_polygon, bounding_box_angle_centroid)) -> meshlist
  return(meshlist)
}

pivot_xy_longer <- function(celllist, .xy_cols, num, n) {
  celllist |>
    pivot_longer({{.xy_cols}}, names_to = c(".value", "XY"), names_pattern = "(.)(.)") |>
    mutate({{num}} := if_else(XY == 1, {{n}} - {{num}}, {{num}})) |>
    arrange(XY, {{num}}) |>
    select(-c(XY)) -> celllist
    return(celllist)
}




extract_microbeJ_mesh <- function(microbeJ_df) {
  microbeJ_df |>
  rename(id = NAME.id, name = NAME, index = INDEX, frame = POSITION, x = COORD.x, y = COORD.y) |>
  group_by(id, frame) |>
  arrange(index) |>
  summarise(mesh = list(st_polygon_autoclose(x, y))) |>
  st_sf() -> mesh
  return(mesh)
}

extract_microbeJ_cell <- function(microbeJ_df) {
  lookup <- c(
  "name",  "name_id", "experiment",
  "image", "location_x", "location_y",
  "position", "shape_area", "shape_aspect_ratio",
  "shape_circularity", "shape_length", "shape_orientation",
  "shape_perimeter", "shape_roundness", "shape_solidity",
  "shape_width")

  names(lookup) <- c(
  "name", "id", "experiment",
  "image", "x", "y",
  "position", "area", "aspect_ratio",
  "circularity", "length", "orientation",
  "perimeter", "roundness", "solidity",
  "width")

  microbeJ_df <- janitor::clean_names(microbeJ_df)
  microbeJ_df |>
    select(any_of(lookup)) |>
    rename(any_of(lookup)) -> cell_list

    return(cell_list)
}


#################################################################################

#Functions related to other segmentation programs than oufti or microbej, untested:


extract_morphometrics <- function(morphometrics_list) {
  morphometrics_list |> 
    as_tibble() |>
    mutate(across(where(\(x) length(dim(x)) == 2 && dim(x)[2] == 1), \(x) c(x))) -> temp
  purrr::map(temp$frame, \(x) as_tibble(t(data.frame(x)))) -> temp
  
  temp[[2]] |>
    rowwise() |> 
    mutate(
      across(c(Xcent, Ycent, area, theta, bw.label, cellID, circularity, pole1, pole2, num.pts, Xcent.cont, Ycent.cont,theta.cont), \(x) c(x)),
      mesh_cont = list(st_polygon_autoclose(Xcont, Ycont)),
      mesh_perim = list(st_polygon_autoclose(Xperim, Yperim))) |> 
    select(-c(Xcont, Ycont, Xperim, Yperim)) |>
    st_sf() -> cell_list
  
  return(cell_list)
}


extract_supersegger_celllist <- function(supersegger_list) {
  lookup <- c("cell_id", "cell_birth_time", "cell_death_time", "cell_age", "fluor1_sum", "fluor1_mean", "fluor1_sum_death", "fluor1_mean_death", "fluor2_sum", "fluor2_mean", "fluor2_sum_death", "fluor2_mean_death", "mother_id", "daughter1_id", "daughter2_id")
  names(lookup) <- c("cell", "birth", "death", "edgelength", "fluorsum", "fluormean", "fluorsum_D", "fluormean_D", "fluorsum2", "fluormean2", "fluorsum_D2", "fluormean_D2", "parent", "child1", "child2")
  
  as_tibble(supersegger_list$data) -> cell_list
  colnames(cell_list) <- janitor::make_clean_names(unlist(supersegger_list$def))
  cell_list |>
    select(any_of(lookup)) |>
    rename(any_of(lookup)) |>
    mutate(
      parent = if_else(is.na(parent), 0, parent)
    ) -> cell_list
  
}

# segger_files |> 
#   purrr::map(\(x) extract_supersegger_mesh(R.matlab::readMat(x))) |> 
#   bind_rows() -> all_cells

extract_supersegger_mesh <- function(suppersegger_list) {
  suppersegger_list$CellA[[1]][[1]][,,1] -> temp
  mesh <- terra::rast(temp$mask) |> 
    terra::flip(direction="horizontal") |>
    as.polygons() |>
    terra::shift(dx = temp$r.offset[,1], dy = temp$r.offset[,2]) |>
    st_as_sf() |>
    rename(value = lyr.1) |>
    filter(value > 0)
  return(mesh)
}


trim_orphan <- function(datasegger) {
  datasegger |>
    rowwise() |>
    filter(any(parent != 0, !is.na(child1), !is.na(child2))) -> datasegger
  
  return(datasegger)
}


