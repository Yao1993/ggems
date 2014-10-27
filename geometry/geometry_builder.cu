// This file is part of GGEMS
//
// GGEMS is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// GGEMS is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with GGEMS.  If not, see <http://www.gnu.org/licenses/>.
//
// GGEMS Copyright (C) 2013-2014 Julien Bert

#ifndef GEOMETRY_BUILDER_CU
#define GEOMETRY_BUILDER_CU

#include "geometry_builder.cuh"

/////////////////////////////////////////////////////////////////////////////////////
///////// Host/Device functions /////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////

// Function that return the material of a volume
unsigned int __host__ __device__ get_geometry_material(Scene geometry, unsigned int id_geom) {
    unsigned int adr_geom = geometry.ptr_objects[id_geom];
    unsigned int obj_type = (unsigned int)geometry.data_objects[adr_geom+ADR_OBJ_TYPE];

    if (obj_type != VOXELIZED) {
        return (unsigned int)geometry.data_objects[adr_geom+ADR_OBJ_MAT_ID];
    } else {
        // TODO
        return 0;
    }
}

// Find the next geometry along the path of the particle
void __host__ __device__ get_next_geometry_boundary(Scene geometry, unsigned int cur_geom,
                                                     float3 pos, float3 dir,
                                                     float &interaction_distance,
                                                     unsigned int &geometry_volume) {


    interaction_distance = FLT_MAX;
    geometry_volume = cur_geom;
    float distance;

    unsigned int adr_geom = geometry.ptr_objects[cur_geom];
    unsigned int obj_type = (unsigned int)geometry.data_objects[adr_geom+ADR_OBJ_TYPE];

    // First check the boundary of the current volume
    if (obj_type == AABB) {

        // Read first the bounding box
        float xmin = geometry.data_objects[adr_geom+ADR_AABB_XMIN];
        float xmax = geometry.data_objects[adr_geom+ADR_AABB_XMAX];
        float ymin = geometry.data_objects[adr_geom+ADR_AABB_YMIN];
        float ymax = geometry.data_objects[adr_geom+ADR_AABB_YMAX];
        float zmin = geometry.data_objects[adr_geom+ADR_AABB_ZMIN];
        float zmax = geometry.data_objects[adr_geom+ADR_AABB_ZMAX];

        distance = hit_ray_AABB(pos, dir, xmin, xmax, ymin, ymax, zmin, zmax);
        //geometry_volume = geometry.mother_node[cur_geom];

        if (distance <= interaction_distance) {
            interaction_distance = distance + EPSILON3; // overshoot
            geometry_volume = geometry.mother_node[cur_geom];
        }

    } else if (obj_type == SPHERE) {
        // TODO

    } // else if VOXELIZED   ... etc.

    // Then check every child contains in this node
    unsigned int adr_node = geometry.ptr_nodes[cur_geom];

    unsigned int offset_node = 0;
    unsigned int id_child_geom;
    while (offset_node < geometry.size_of_nodes[cur_geom]) {

        // Child id
        id_child_geom = geometry.child_nodes[adr_node + offset_node];

        // Determine the type of the volume
        unsigned int adr_child_geom = geometry.ptr_objects[id_child_geom];
        unsigned int obj_child_type = (unsigned int)geometry.data_objects[adr_child_geom+ADR_OBJ_TYPE];

        // Get raytracing distance accordingly
        if (obj_child_type == AABB) {

            // Read first the bounding box
            float xmin = geometry.data_objects[adr_child_geom+ADR_AABB_XMIN];
            float xmax = geometry.data_objects[adr_child_geom+ADR_AABB_XMAX];
            float ymin = geometry.data_objects[adr_child_geom+ADR_AABB_YMIN];
            float ymax = geometry.data_objects[adr_child_geom+ADR_AABB_YMAX];
            float zmin = geometry.data_objects[adr_child_geom+ADR_AABB_ZMIN];
            float zmax = geometry.data_objects[adr_child_geom+ADR_AABB_ZMAX];

            // Ray/AABB raytracing
            distance = hit_ray_AABB(pos, dir, xmin, xmax, ymin, ymax, zmin, zmax);

            if (distance <= interaction_distance) {
                interaction_distance = distance + EPSILON3; // overshoot
                geometry_volume = id_child_geom;
            }

        } else if (obj_child_type == SPHERE) {
            // do
        } // else if VOXELIZED   ... etc.

        ++offset_node;

    }
}

/////////////////////////////////////////////////////////////////////////////////////
///////// Geometry Builder class ////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////

GeometryBuilder::GeometryBuilder() {

    // Init the size of the structure Geometry
    world.ptr_objects_dim = 0;
    world.size_of_objects_dim = 0;
    world.data_objects_dim = 0;
    world.ptr_nodes_dim = 0;
    world.size_of_nodes_dim = 0;
    world.child_nodes_dim = 0;
    world.mother_node_dim = 0;

    // Init the first node id
    world.cur_node_id = 0;
}

///// Private ////////////////////////////////////////////////////

// Update the tree address
void GeometryBuilder::update_tree_address() {
    world.ptr_nodes[0] = 0;
    unsigned int i=1;
    while (i < world.ptr_nodes_dim) {
        world.ptr_nodes[i] = world.ptr_nodes[i-1] + world.size_of_nodes[i-1];
        ++i;
    }
}

// Search and return the material index for a given material name
unsigned int GeometryBuilder::get_material_index(std::string material_name) {

    // Check if this material is already used, if it is return the corresponding index
    unsigned int index = 0;
    while (index < materials_list.size()) {
        if (materials_list[index] == material_name) return index;
        ++index;
    }

    // If it is not, add a new entry into the material table
    index = materials_list.size();
    materials_list.push_back(material_name);

    return index;
}

///// Hierarchical structure of the geometry ////////////////////////

// Add the root
void GeometryBuilder::add_root() {

    array_push_back(&world.ptr_nodes, world.ptr_nodes_dim, 0);
    array_push_back(&world.size_of_nodes, world.size_of_nodes_dim, 0);
    array_push_back(&world.mother_node, world.mother_node_dim, 0);
    world.cur_node_id = 0;

}

// Add a node
void GeometryBuilder::add_node(unsigned int mother_id) {
    // New node ID
    world.cur_node_id++;

    // Insert this object into the tree
    array_insert(&world.child_nodes, world.child_nodes_dim,
                 world.ptr_nodes[mother_id]+world.size_of_nodes[mother_id], world.cur_node_id);

    // Update the tree
    world.size_of_nodes[mother_id]++;
    array_push_back(&world.size_of_nodes, world.size_of_nodes_dim, 0);
    array_push_back(&world.ptr_nodes, world.ptr_nodes_dim, world.cur_node_id);
    array_push_back(&world.mother_node, world.mother_node_dim, mother_id);

    // Update tree address
    update_tree_address();
}

// Print the tree structure of the geometry
void GeometryBuilder::print_tree() {
    // print each node
    unsigned int i = 0;
    unsigned int j = 0;
    while (i < world.size_of_nodes_dim) {
        printf("(mother: %i)--[node: %i]--(childs: ", world.mother_node[i], i);
        j=0; while (j < world.size_of_nodes[i]) {
            printf("%i,", world.child_nodes[world.ptr_nodes[i]+j]);
            ++j;
        }
        printf(")\n");
        ++i;
    }
    printf("\n");
}

///// Utils ////////////////////////////////////////////////////////////////////////////////

// Print the current world
void GeometryBuilder::print_geometry() {
    // Print out the tree structure
    print_tree();

    // Print out every object name
    unsigned int i;
    printf("List of object:\n");
    i=0; while (i < name_objects.size()) {
        printf("%i - %s\n", i, name_objects[i].c_str());
        ++i;
    }
    printf("\n");

    // Print out every material name
    printf("List of material:\n");
    i=0; while (i < materials_list.size()) {
        printf("%i - %s\n", i, materials_list[i].c_str());
        ++i;
    }
    printf("\n");

    // Print out each object contains on the tree
    i=0; while (i < world.ptr_objects_dim) {
        // Get obj address
        unsigned int address_obj = world.ptr_objects[i];

        // Object name
        printf("::: %s :::\n", name_objects[i].c_str());

        // Same header for everyone
        unsigned int type = (unsigned int)(world.data_objects[address_obj+ADR_OBJ_TYPE]);
        unsigned int mat = (unsigned int)(world.data_objects[address_obj+ADR_OBJ_MAT_ID]);
        float xmin = world.data_objects[address_obj+ADR_AABB_XMIN];
        float xmax = world.data_objects[address_obj+ADR_AABB_XMAX];
        float ymin = world.data_objects[address_obj+ADR_AABB_YMIN];
        float ymax = world.data_objects[address_obj+ADR_AABB_YMAX];
        float zmin = world.data_objects[address_obj+ADR_AABB_ZMIN];
        float zmax = world.data_objects[address_obj+ADR_AABB_ZMAX];

        // Print information0
        switch (type) {
        case AABB:
            printf("type: AABB\n"); break;
        case SPHERE:
            printf("type: SPHERE\n"); break;
        } // switch

        printf("material: %s\n", materials_list[mat].c_str());
        printf("xmin: %f xmax: %f ymin: %f ymax: %f zmin: %f zmax: %f\n\n",
                xmin, xmax, ymin, ymax, zmin, zmax);


        ++i;
    } // while
}



/*
// Print out the geometry raw data
void GeometryBuilder::print_raw() {

    // Print out every object name
    unsigned int i;
    printf("List of object [%lu]: ", World.name_objects.size());
    i=0; while (i < World.name_objects.size()) {
        printf("%s ", World.name_objects[i].c_str());
        ++i;
    }
    printf("\n\n");

    // Print out every material name
    printf("List of material [%lu]: ", World.materials_list.size());
    i=0; while (i < World.materials_list.size()) {
        printf("%s ", World.materials_list[i].c_str());
        ++i;
    }
    printf("\n\n");

    // Print out size of objects
    printf("Size of objects [%lu]: ", World.size_of_objects.size());
    i=0; while (i < World.size_of_objects.size()) {
        printf("%i ", World.size_of_objects[i]);
        ++i;
    }
    printf("\n\n");

    // Print out object addresses
    printf("Object addresses [%lu]: ", World.ptr_objects.size());
    i=0; while (i < World.ptr_objects.size()) {
        printf("%i ", World.ptr_objects[i]);
        ++i;
    }
    printf("\n\n");

    // Print out object data
    printf("Object data [%lu]: ", World.data_objects.size());
    i=0; while (i < World.data_objects.size()) {
        printf("%f ", World.data_objects[i]);
        ++i;
    }
    printf("\n\n");

}
*/

/*
// Save the world in order to share an use it later
void GeometryBuilder::save_ggems_geometry(std::string filename) {

    // check extension
    if (filename.size() < 10) {
        printf("Error, to export a ggems geometry, the exension must be '.ggems_geom'!\n");
        return;
    }
    std::string ext = filename.substr(filename.size()-10);
    if (ext!="ggems_geom") {
        printf("Error, to export a ggems geometry, the exension must be '.ggems_geom'!\n");
        return;
    }

    FILE *pfile = fopen(filename.c_str(), "wb");
    unsigned int i, nb, tmp;

    // .: Tree :.  -  First export the tree that structure the world

    // 1. ptr_nodes [N, data]
    nb = World.tree.ptr_nodes.size();
    fwrite(&nb, 1, sizeof(unsigned int), pfile);
    fwrite(World.tree.ptr_nodes.data(), nb, sizeof(unsigned int), pfile);

    // 2. size_of_nodes [N, data]
    nb = World.tree.size_of_nodes.size();
    fwrite(&nb, 1, sizeof(unsigned int), pfile);
    fwrite(World.tree.size_of_nodes.data(), nb, sizeof(unsigned int), pfile);

    // 3. child_nodes [N, data]
    nb = World.tree.child_nodes.size();
    fwrite(&nb, 1, sizeof(unsigned int), pfile);
    fwrite(World.tree.child_nodes.data(), nb, sizeof(unsigned int), pfile);

    // 4. mother_node [N, data]
    nb = World.tree.mother_node.size();
    fwrite(&nb, 1, sizeof(unsigned int), pfile);
    fwrite(World.tree.mother_node.data(), nb, sizeof(unsigned int), pfile);

    // 5. cur_node_id [val]
    fwrite(&World.tree.cur_node_id, 1, sizeof(unsigned int), pfile);

    // .: World :.  -  Then export the world

    // 6. name_objects [N, data]
    nb = World.name_objects.size();
    fwrite(&nb, 1, sizeof(unsigned int), pfile);
    i=0; while (i < nb) {
        tmp = World.name_objects[i].size();
        fwrite(&tmp, 1, sizeof(unsigned int), pfile);
        fwrite(World.name_objects[i].c_str(), World.name_objects[i].size(), sizeof(char), pfile);
        ++i;
    }

    // 7. materials_list [N, data]
    nb = World.materials_list.size();
    fwrite(&nb, 1, sizeof(unsigned int), pfile);
    i=0; while (i < nb) {
        tmp = World.materials_list[i].size();
        fwrite(&tmp, 1, sizeof(unsigned int), pfile);
        fwrite(World.materials_list[i].c_str(), World.materials_list[i].size(), sizeof(char), pfile);
        ++i;
    }

    // 8. ptr_objects [N, data]
    nb = World.ptr_objects.size();
    fwrite(&nb, 1, sizeof(unsigned int), pfile);
    fwrite(World.ptr_objects.data(), nb, sizeof(unsigned int), pfile);

    // 9. size_of_objects [N, data]
    nb = World.size_of_objects.size();
    fwrite(&nb, 1, sizeof(unsigned int), pfile);
    fwrite(World.size_of_objects.data(), nb, sizeof(unsigned int), pfile);

    // 10. data_objects [N, data] (the big one!!!)
    nb = World.data_objects.size();
    fwrite(&nb, 1, sizeof(unsigned int), pfile);
    fwrite(World.data_objects.data(), nb, sizeof(float), pfile);


    fclose(pfile);
}
*/


////
////////////////////// Object management ///////////////////////////////////////////////////
////
//
// !!!! Convention of the head of any object written in the world structure !!!!
//
// Object Type
//  array_push_back(world.data_objects, world.data_objects_dim, (float)AABB);
// Material index
//  array_push_back(world.data_objects, world.data_objects_dim, (float)get_material_index(obj.material_name));
// AABB parameters
//  array_push_back(world.data_objects, world.data_objects_dim, obj.xmin);
//  array_push_back(world.data_objects, world.data_objects_dim, obj.xmax);
//  array_push_back(world.data_objects, world.data_objects_dim, obj.ymin);
//  array_push_back(world.data_objects, world.data_objects_dim, obj.ymax);
//  array_push_back(world.data_objects, world.data_objects_dim, obj.zmin);
//  array_push_back(world.data_objects, world.data_objects_dim, obj.zmax);
// Name of this object
//  name_objects.push_back(obj.object_name);

// Add the world
unsigned int GeometryBuilder::add_world(Aabb obj) {

    // Add the root tree
    add_root();

    // Put this object into buffer
    buffer_aabb[world.cur_node_id] = obj;
    buffer_obj_type[world.cur_node_id] = AABB;

    return world.cur_node_id;

}

// Add an AABB object into the world
unsigned int GeometryBuilder::add_object(Aabb obj, unsigned int mother_id) {

    // Add this object to the tree
    add_node(mother_id);

    // Put this object into buffer
    buffer_aabb[world.cur_node_id] = obj;
    buffer_obj_type[world.cur_node_id] = AABB;

    return world.cur_node_id;
}

// Add a Sphere object into the world
unsigned int GeometryBuilder::add_object(Sphere obj, unsigned int mother_id) {

    // Add this object to the tree
    add_node(mother_id);

    // Put this object into buffer
    buffer_sphere[world.cur_node_id] = obj;
    buffer_obj_type[world.cur_node_id] = SPHERE;

    return world.cur_node_id;

}

// Build AABB object into the scene structure
void GeometryBuilder::build_object(Aabb obj) {
    printf("Building AABB\n");

    // Store the address to access to this object
    array_push_back(&world.ptr_objects, world.ptr_objects_dim, world.data_objects_dim);

    // Store the information of this object

    // Object Type
    array_push_back(&world.data_objects, world.data_objects_dim, (float)AABB);
    // Material index
    array_push_back(&world.data_objects, world.data_objects_dim, (float)get_material_index(obj.material_name));
     // AABB parameters
    array_push_back(&world.data_objects, world.data_objects_dim, obj.xmin);
    array_push_back(&world.data_objects, world.data_objects_dim, obj.xmax);
    array_push_back(&world.data_objects, world.data_objects_dim, obj.ymin);
    array_push_back(&world.data_objects, world.data_objects_dim, obj.ymax);
    array_push_back(&world.data_objects, world.data_objects_dim, obj.zmin);
    array_push_back(&world.data_objects, world.data_objects_dim, obj.zmax);
    // Name of this object
    name_objects.push_back(obj.object_name);
    // Color of this object
    object_colors.push_back(obj.color);
    // Transparency of this object
    object_transparency.push_back(obj.transparency);
    // Store the size of this object
    array_push_back(&world.size_of_objects, world.size_of_objects_dim, SIZE_AABB_OBJ);

    printf("    Done\n");
}

// Build sphere object into the scene structure
void GeometryBuilder::build_object(Sphere obj) {
    // Store the address to access to this object
    array_push_back(&world.ptr_objects, world.ptr_objects_dim, world.data_objects_dim);

    // Store the information of this object

    // Object Type
    array_push_back(&world.data_objects, world.data_objects_dim, (float)SPHERE);
    // Material index
    array_push_back(&world.data_objects, world.data_objects_dim, (float)get_material_index(obj.material_name));
     // AABB parameters
    array_push_back(&world.data_objects, world.data_objects_dim, obj.xmin);
    array_push_back(&world.data_objects, world.data_objects_dim, obj.xmax);
    array_push_back(&world.data_objects, world.data_objects_dim, obj.ymin);
    array_push_back(&world.data_objects, world.data_objects_dim, obj.ymax);
    array_push_back(&world.data_objects, world.data_objects_dim, obj.zmin);
    array_push_back(&world.data_objects, world.data_objects_dim, obj.zmax);
    // Name of this object
    name_objects.push_back(obj.object_name);
    // Color of this object
    object_colors.push_back(obj.color);
    // Transparency of this object
    object_transparency.push_back(obj.transparency);
    // Sphere parameters
    array_push_back(&world.data_objects, world.data_objects_dim, obj.cx);
    array_push_back(&world.data_objects, world.data_objects_dim, obj.cy);
    array_push_back(&world.data_objects, world.data_objects_dim, obj.cz);
    array_push_back(&world.data_objects, world.data_objects_dim, obj.radius);
    // Store the size of this object
    array_push_back(&world.size_of_objects, world.size_of_objects_dim, SIZE_SPHERE_OBJ);
}

// Build the complete scene
void GeometryBuilder::build_scene() {

    // Scan every object a build it to the scene structure

    unsigned int i = 0;
    while (i < world.ptr_nodes_dim) {
        printf("Building object id %i = %i\n", i, buffer_obj_type[i]);

        // AABB
        if (buffer_obj_type[i] == AABB) {
            build_object(buffer_aabb[i]);
        // Sphere
        } else if (buffer_obj_type[i] == SPHERE) {
            build_object(buffer_sphere[i]);
        }

        ++i;
    }

    printf("Building done\n");


    print_tree();

    // Print out every object name
    printf("List of object:\n");
    i=0; while (i < name_objects.size()) {
        printf("%i - %s\n", i, name_objects[i].c_str());
        ++i;
    }
    printf("\n");

}























/*
// Add a Meshed object into the world
unsigned int GeometryBuilder::add_object(Meshed obj, unsigned int mother_id) {

    // Add this object to the tree
    World.tree.add_node(mother_id);

    // Store the address to access to this object
    World.ptr_objects.push_back(World.data_objects.size());

    // Store the information of this object
    World.data_objects.push_back(MESHED);                                // Object Type
    World.data_objects.push_back(get_material_index(obj.material_name)); // Material index

    // Add the boudning box of this mesh
    World.data_objects.push_back(obj.xmin);
    World.data_objects.push_back(obj.xmax);
    World.data_objects.push_back(obj.ymin);
    World.data_objects.push_back(obj.ymax);
    World.data_objects.push_back(obj.zmin);
    World.data_objects.push_back(obj.zmax);

    // Number of triangles
    World.data_objects.push_back(obj.number_of_triangles);

    // Append octree information
    World.data_objects.push_back(obj.octree_type); // NO_OCTREE, REG_OCTREE, ADP_OCTREE
    if (obj.octree_type == REG_OCTREE) {
        World.data_objects.push_back(obj.nb_cell_x); // Octree size in cells
        World.data_objects.push_back(obj.nb_cell_y);
        World.data_objects.push_back(obj.nb_cell_z);
    }

    // Append every triangle
    World.data_objects.reserve(World.data_objects.size() + obj.vertices.size());
    World.data_objects.insert(World.data_objects.end(), obj.vertices.begin(), obj.vertices.end());

    // Append the octree if defined
    if (obj.octree_type == REG_OCTREE) {
        // Append the number of objects per cell
        World.data_objects.reserve(World.data_objects.size() + obj.nb_objs_per_cell.size());
        World.data_objects.insert(World.data_objects.end(), obj.nb_objs_per_cell.begin(),
                                                            obj.nb_objs_per_cell.end());
        // Append the addr of each cell
        World.data_objects.reserve(World.data_objects.size() + obj.addr_to_cell.size());
        World.data_objects.insert(World.data_objects.end(), obj.addr_to_cell.begin(),
                                                            obj.addr_to_cell.end());
        // Append the list of objects per cell
        World.data_objects.reserve(World.data_objects.size() + obj.list_objs_per_cell.size());
        World.data_objects.insert(World.data_objects.end(), obj.list_objs_per_cell.begin(),
                                                            obj.list_objs_per_cell.end());
    }

    // Name of this object
    World.name_objects.push_back(obj.object_name);

    // Store the size of this object
    if (obj.octree_type == REG_OCTREE) {
        World.size_of_objects.push_back(obj.vertices.size() + obj.nb_objs_per_cell.size() +
                                        obj.addr_to_cell.size() + obj.list_objs_per_cell.size() + 13);
    } else { // NO_OCTREE
        World.size_of_objects.push_back(obj.vertices.size()+10);
    }

    return World.tree.get_current_id();

}

// Add a Meshed object into the world
unsigned int GeometryBuilder::add_object(Voxelized obj, unsigned int mother_id) {

    // Add this object to the tree
    World.tree.add_node(mother_id);

    // Store the address to access to this object
    World.ptr_objects.push_back(World.data_objects.size());

    // Store the information of this object
    World.data_objects.push_back(VOXELIZED);              // Object Type

    World.data_objects.push_back(-1.0f);                  // Heterogeneous material

    // Add the bounding box of this phantom
    World.data_objects.push_back(obj.xmin);
    World.data_objects.push_back(obj.xmax);
    World.data_objects.push_back(obj.ymin);
    World.data_objects.push_back(obj.ymax);
    World.data_objects.push_back(obj.zmin);
    World.data_objects.push_back(obj.zmax);

    // Store the parameters of this object
    World.data_objects.push_back(obj.number_of_voxels);
    World.data_objects.push_back(obj.nb_vox_x);
    World.data_objects.push_back(obj.nb_vox_y);
    World.data_objects.push_back(obj.nb_vox_z);
    World.data_objects.push_back(obj.spacing_x);
    World.data_objects.push_back(obj.spacing_y);
    World.data_objects.push_back(obj.spacing_z);

    // Here we need to merge and update the material ID according the current list of mats

    // Build a LUT to convert the old id in new one
    std::vector<unsigned int> new_id;
    unsigned int i = 0;
    while (i < obj.list_of_materials.size()) {
        new_id.push_back(get_material_index(obj.list_of_materials[i]));
        ++i;
    }

    // Now convert every material ID contains on the voxelized volume
    i=0; while (i < obj.number_of_voxels) {
        obj.data[i] = new_id[obj.data[i]];
        ++i;
    }

    // Finally append voxelized data into the world
    World.data_objects.reserve(World.data_objects.size() + obj.data.size());
    World.data_objects.insert(World.data_objects.end(), obj.data.begin(), obj.data.end());

    // Name of this object
    World.name_objects.push_back(obj.object_name);

    // Store the size of this object
    World.size_of_objects.push_back(obj.data.size()+15);

    return World.tree.get_current_id();

}
*/
#endif
