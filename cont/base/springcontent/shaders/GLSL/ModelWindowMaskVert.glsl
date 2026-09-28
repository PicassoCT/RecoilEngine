/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */
#version 120
void main() {
	gl_Position = gl_ModelViewProjectionMatrix * gl_Vertex;
}
