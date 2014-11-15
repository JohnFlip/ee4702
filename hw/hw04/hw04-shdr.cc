/// LSU EE 4702-1 (Fall 2014), GPU Programming
//
 /// Homework 4
 //
 //  Use this file for your solution.

 /// Instructions
 //
 //  Read the assignment: http://www.ece.lsu.edu/koppel/gpup/2014/hw04.pdf

//Phillip Marr
// searching for //**** marks the start and end of my changes inside the shaders

// Specify version of OpenGL Shading Language.
//
#version 430 compatibility

// Number of triangle pairs between balls.
//
layout ( location = 1 ) uniform int opt_segments;

// Number of balls.
//
layout ( location = 2 ) uniform int chain_length;

// Use this variable to debug your code. Press 'd' to toggle
// debug_bool.x and 'D' to toggle debug_bool.y (between true and
// false).
//
layout ( location = 3 ) uniform bvec2 debug_bool;

// Use this to debug your code. Press TAB until "debug_float"
// appears, then press +/- to adjust its value.
//
layout ( location = 4 ) uniform float debug_float;

//layout ( location = 5 ) uniform pColor color_lsu_spirit_gold;
//layout ( location = 6 ) uniform pColor color_lsu_spirit_purple;


// Array of ball positions.
//
layout ( binding = 1 ) buffer Balls_Pos { vec4 balls_pos[]; };


#ifdef _VERTEX_SHADER_

// Redefine this vertex shader input to be an integer vector.
//
in ivec3 gl_Vertex;


// Interface block for vertex shader output / geometry shader input.
//
out Data_to_GS
{
  vec3 normal_e;
  vec4 vertex_e;
  vec4 vertex_u; //bottom spiral
  vec3 normal_u; //probably unneeded
  vec4 color;
  vec2 gl_TexCoord[1];
  vec4 gl_Position;
  vec4 u_position;
  flat int edge; //inner set as an int since booleans caused weird graphics glitches
  flat int wall; //tracks when to color gray

  // Any changes here must also be made to the fragment shader input.

};


void
vs_main()
{
  const float spiral_radius = 0.5;
  const float omega = 10;

  const int bidx = gl_Vertex.x;
  const int ti = gl_Vertex.y;
  const bool inner = gl_Vertex.z == 1;
 //**** start of my changes
  if(inner)
    edge = 1;
  else
    edge = 0;
  wall = 0;
 //**** end of my changes

  const int radial_idx = bidx * opt_segments + ti;
  const float delta_t = 1.0 / opt_segments;
  const float t = float(ti) * delta_t;
  const float theta = delta_t * radial_idx * omega;

  vec3 pos1 = balls_pos[bidx-1].xyz;
  vec3 pos2 = balls_pos[bidx].xyz;

  vec3 v12 = pos2.xyz - pos1.xyz;

  // Find a vector that's orthogonal to v12.
  //
  vec3 van =
    normalize(v12.x == 0 ? vec3(0,v12.z,-v12.y) : vec3(v12.y,-v12.x,0));

  // Find a vector that's orthogonal to v12 and van.
  //
  vec3 vbn = normalize(cross(v12,van));

  vec3 va = van * spiral_radius;
  vec3 vb = vbn * spiral_radius;

  // Point on line between ball1 and ball2.
  //
  vec3 p = pos1 + t * v12;

  // Vector from p to spiral outer edge.
  //
  vec3 radial = va * cos(theta) + vb * sin(theta);
  vec3 p_outer = p + radial;

  const float inner_frac = 0.5;
  vec3 p_inner = p + inner_frac * radial;

  // Compute surface normals.
  //
  vec3 tangial = -omega * va * sin(theta) + omega * vb * cos(theta);
  vec3 tang = v12 + tangial;
  vec3 tang_inner = v12 + inner_frac * tangial;
  vec3 norm = normalize(cross(radial,tang));
  vec3 norm_inner = normalize(cross(radial,tang_inner));

  // The code above computed both the inner and outer spiral
  // points. But, we only need one of them. Tsk, tsk, that's wasteful!
  //
  vec4 position = vec4( inner ? p_inner : p_outer, 1 );
  vec3 normal_o = inner ? norm_inner : norm;

  // Write position and normal to shader output variables. Position
  // is written in both eye and clip space.
  //
  gl_Position = gl_ModelViewProjectionMatrix * position;
  normal_e = gl_NormalMatrix * normal_o;
  vertex_e = gl_ModelViewMatrix * position;

  //**** start of my changes
  vec3 d_norm = normalize(v12) * 0.1;
  vec4 u_pos = position;
  u_pos.xyz = u_pos.xyz +  d_norm.xyz;
  u_pos.w = 1;

  u_position = gl_ModelViewProjectionMatrix * u_pos;
  normal_u = gl_NormalMatrix * normal_o;
  vertex_u = gl_ModelViewMatrix * u_pos;
  //**** end of my changes
  
  //vertex_u = vertex_e + d_norm * 0.5;
  // normal_u = normal_e;
 
  // Amount by which to zoom the texture.
  //
  float tex_zoom = 0.5;

  // Uncomment the line below to use "debug_float" to zoom text.
  // tex_zoom /= debug_float;

  const float du = 0.5 * tex_zoom / chain_length;
  const float u = float(bidx) * du;

  gl_TexCoord[0].x = tex_zoom * t;
  gl_TexCoord[0].y = u + (inner ? du : 0 );

  // Pass through color unchanged.
  //
  color = gl_Color;
}

#endif


#ifdef _GEOMETRY_SHADER_

in Data_to_GS
{
  vec3 normal_e;
  vec4 vertex_e;
  vec4 vertex_u;
  vec3 normal_u;
  vec4 color;
  vec2 gl_TexCoord[1];
  vec4 gl_Position;
  vec4 u_position;
  flat int edge;
  flat int wall;
} In[];

out Data_to_FS
{
  vec3 normal_e;
  vec4 vertex_e;
  vec4 vertex_u;
  vec3 normal_u;
  vec2 gl_TexCoord[1];
  flat int edge;
  flat int wall;
  flat vec4 color;
};

// Type of primitive at geometry shader input.
//
layout ( triangles ) in;

// Type of primitives emitted geometry shader output.
//
layout ( triangle_strip, max_vertices = 50 ) out;

void
gs_main_simple()
{
  // DO NOT MODIFY THIS ROUTINE.
  // This shader used with Method 1.

  // Pass the triangle unchanged.

  for ( int i=0; i<3; i++ )
    {
      normal_e = In[i].normal_e;
      vertex_e = In[i].vertex_e;
      color = In[i].color;
      gl_Position = In[i].gl_Position;
      gl_TexCoord[0] = In[i].gl_TexCoord[0];
      EmitVertex();
    }
  EndPrimitive();
  // DO NOT MODIFY THIS ROUTINE.
}


void
gs_main_solution()
{
  // PROBLEM 2 Solution Goes Here
  
  for ( int i=0; i<3; i++ )
    {
      normal_e = In[i].normal_e;
      vertex_e = In[i].vertex_e;
      color = In[i].color;
      gl_Position = In[i].gl_Position;
      gl_TexCoord[0] = In[i].gl_TexCoord[0];
      wall = 0;
      EmitVertex();
    }
   EndPrimitive();

  for ( int i=0; i<3; i++ )
    {
      normal_u = In[i].normal_u;
      vertex_u = In[i].vertex_u;
      color = In[i].color;
      gl_Position = In[i].u_position;
      gl_TexCoord[0] = In[i].gl_TexCoord[0];
      wall = 0;
      EmitVertex();
   }
  
    EndPrimitive();
  
  
  int edge1,edge2;
  if(In[0].edge == In[2].edge)
    {
      edge1 = 0; edge2 = 2; 
    }
    else
    {
      edge1 = 1; edge2 = 2;
    }
  
  //edge1 = 1; edge2 = 2;
   //uvu bottom, top, bottom
      normal_u = In[edge1].normal_u;
      vertex_u = In[edge1].vertex_u;
      color = In[edge1].color;
      gl_Position = In[edge1].u_position;
      gl_TexCoord[0] = In[edge1].gl_TexCoord[0];
      wall++;
      EmitVertex();
     
      normal_e = In[edge1].normal_e;
      vertex_e = In[edge1].vertex_e;
      color = In[edge1].color;
      gl_Position = In[edge1].gl_Position;
      gl_TexCoord[0] = In[edge1].gl_TexCoord[0];
      wall++;
      EmitVertex();

      normal_u = In[edge2].normal_u;
      vertex_u = In[edge2].vertex_u;
      color = In[edge2].color;
      gl_Position = In[edge2].u_position;
      gl_TexCoord[0] = In[edge2].gl_TexCoord[0];
      wall++;
      EmitVertex();

      EndPrimitive();

      //vuv top, bottom, top
      normal_e = In[edge1].normal_e;
      vertex_e = In[edge1].vertex_e;
      color = In[edge1].color;
      gl_Position = In[edge1].gl_Position;
      gl_TexCoord[0] = In[edge1].gl_TexCoord[0];
      wall++;
      EmitVertex();

      normal_u = In[edge2].normal_u;
      vertex_u = In[edge2].vertex_u;
      color = In[edge2].color;
      gl_Position = In[edge2].u_position;
      gl_TexCoord[0] = In[edge2].gl_TexCoord[0];
      wall++;
      EmitVertex();

      normal_e = In[edge2].normal_e;
      vertex_e = In[edge2].vertex_e;
      color = In[edge2].color;
      gl_Position = In[edge2].gl_Position;
      gl_TexCoord[0] = In[edge2].gl_TexCoord[0];
      wall++;
      EmitVertex();

      EndPrimitive();
}

#endif


#ifdef _FRAGMENT_SHADER_

in Data_to_FS
{
  vec3 normal_e;
  vec4 vertex_e;
  vec4 vertex_u;
  vec3 normal_u;
  vec2 gl_TexCoord[];
  flat vec4 color;
  flat int edge;
  flat int wall;

};

uniform sampler2D tex_unit_0;
vec4 generic_lighting(vec4 vertex_e, vec4 color, vec3 normal_e);

void
fs_main()
{
  // Perform lighting, fetch and blend texture, then emit fragment.
  //
 
  // Get filtered texel.
  //
  vec4 texel = texture( tex_unit_0, gl_TexCoord[0].xy );

  //**** start of my changes
 
  if(gl_FrontFacing) //front is gold.
    {
      gl_FragColor = texel * generic_lighting(vertex_e, color, normalize(normal_e)) * gl_FrontMaterial.diffuse;
    }
  else //back is purple
     {
      gl_FragColor = texel *  generic_lighting(vertex_e, color, normalize(normal_e)) * gl_BackMaterial.diffuse;
    }
  //if
  if (wall != 0)  //if on the inside or outside of spiral, make gray
    gl_FragColor = texel *  generic_lighting(vertex_e, color, normalize(normal_e)) * gl_FrontMaterial.ambient;

  //add up rgb values, don't draw if less than 0.05
  float rgb = gl_FragColor.r + gl_FragColor.g + gl_FragColor.b;
  if(rgb < 0.05)
    discard;

  //**** end of my changes
    
  // Copy fragment depth unmodified.
  //
  gl_FragDepth = gl_FragCoord.z;
}


///
/// Routine used by Either Vertex or Fragment Shader
///

vec4
generic_lighting(vec4 vertex_e, vec4 color, vec3 normal_e)
{
  // Return lighted color of vertex_e.
  //
  vec4 light_pos = gl_LightSource[0].position;
  vec3 v_vtx_light = light_pos.xyz - vertex_e.xyz;
  float d_n_ve = -dot(normal_e,vertex_e.xyz);
  float d_n_vl = dot(normal_e, normalize(v_vtx_light).xyz);
  bool same_sign = ( d_n_ve > 0 ) == ( d_n_vl > 0 );
  float phase_light = same_sign ? abs(d_n_vl) : 0;

  vec3 ambient_light = gl_LightSource[0].ambient.rgb;
  vec3 diffuse_light = gl_LightSource[0].diffuse.rgb;
  float dist = length(v_vtx_light);
  float distsq = dist * dist;
  float atten_inv =
    gl_LightSource[0].constantAttenuation +
    gl_LightSource[0].linearAttenuation * dist +
    gl_LightSource[0].quadraticAttenuation * distsq;
  vec4 lighted_color;
  lighted_color.rgb =
    color.rgb * gl_LightModel.ambient.rgb
    + color.rgb * ( ambient_light + phase_light * diffuse_light ) / atten_inv;
  lighted_color.a = color.a;
  return lighted_color;
}

#endif
