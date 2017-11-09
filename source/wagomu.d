module wagomu;

/*
* Copyright (C) 2009 The Tegaki project contributors
*
* Ported to D by webfreak
*
* This program is free software; you can redistribute it and/or modify
* it under the terms of the GNU General Public License as published by
* the Free Software Foundation; either version 2 of the License, or
* (at your option) any later version.
*
* This program is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
* GNU General Public License for more details.
*
* You should have received a copy of the GNU General Public License along
* with this program; if not, write to the Free Software Foundation, Inc.,
* 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
*/

import std.algorithm;
import std.file;
import std.math;
import std.range;

@safe:

enum MAGIC_NUMBER = 0x77778888;
enum VEC_DIM_MAX = 4;

struct CharacterInfo
{
	dchar unicode;
	uint n_vectors;
}

struct CharacterGroup
{
	uint n_strokes;
	uint n_chars;
	uint offset;
	void[4] pad;
}

struct CharDist
{
	dchar unicode;
	float distance = 0;
}

struct Character
{
	this(uint numVectors, uint numStrokes)
	{
		this.numStrokes = numStrokes;

		if (numVectors)
			points = new float[VEC_DIM_MAX][numVectors];
	}

	float[VEC_DIM_MAX][] points;
	uint numStrokes;
}

struct Recognizer
{
	int windowSize = 3;
	ubyte[] data;
	uint numCharacters, numGroups, dimension, downsampleThreshold;
	CharacterInfo[] characters;
	CharacterGroup[] groups;
	CharDist[] distm;
	float[] dtw1, dtw2;

	void load(string path) @safe
	{
		data = (() @trusted => cast(ubyte[]) read(path))();

		if (data.length < 20)
			throw new Exception("Not a valid file");

		uint[] header = (() @trusted => (cast(uint*) data.ptr)[0 .. 5])();
		if (header[0] != MAGIC_NUMBER)
			throw new Exception("Not a valid file");

		numCharacters = header[1];
		numGroups = header[2];
		dimension = header[3];
		downsampleThreshold = header[4];

		if (numCharacters == 0 || numGroups == 0)
			throw new Exception("No characters in this model");

		if (
			data.length < 5 * uint.sizeof + numCharacters * CharacterInfo.sizeof
				+ numGroups * CharacterGroup.sizeof)
			throw new Exception("Not a valid file");

		(() @trusted{
			characters = (cast(CharacterInfo*)(data.ptr + 5 * uint.sizeof))[0 .. numCharacters];
			groups = (cast(CharacterGroup*)(
				data.ptr + 5 * uint.sizeof + numCharacters * CharacterInfo.sizeof))[0 .. numGroups];
		})();

		distm = new CharDist[numCharacters];

		const maxnvec = maxNumVectors;

		dtw1 = new float[maxnvec * VEC_DIM_MAX];
		dtw2 = new float[maxnvec * VEC_DIM_MAX];
		dtw1[] = 0;
		dtw2[] = 0;
	}

	uint maxNumVectors() const @safe
	{
		uint maxNumVectors;
		foreach (ref ch; characters)
			if (ch.n_vectors > maxNumVectors)
				maxNumVectors = ch.n_vectors;
		return maxNumVectors;
	}

	/* The euclidean distance is replaced by the sum of absolute
   differences for performance reasons... */
	float localDistance(float[VEC_DIM_MAX] v1, float[VEC_DIM_MAX] v2) const
	{
		float sum = 0;
		for (uint i = 0; i < dimension; i++)
			sum += abs(v2[i] - v1[i]);
		return sum;
	}

	/**
	m [X][ ][ ][ ][ ][r]
		[X][ ][ ][ ][ ][ ]
		[X][ ][ ][ ][ ][ ]
		[X][ ][ ][ ][ ][ ]
		[0][X][X][X][X][X]
										n
	Each cell in the n*m matrix is defined as follows:
			
			dtw(i,j) = local_distance(i,j) + MIN3(dtw(i-1,j-1), dtw(i-1,j), dtw(i,j-1))
	Cells marked with an X are set to infinity.
	The bottom-left cell is set to 0.
	The top-right cell is the result.
	At any given time, we only need two columns of the matrix, thus we use
	two arrays dtw1 and dtw2 as our data structure.
	[   ]   [   ]
	[ j ]   [ j ]
	[j-1]   [j-1]
	[   ]   [   ]
	[ X ]   [ X ]
	dtw1    dtw2
	A cell can thus be calculated as follows:
			dtw2(j) = local_distance(i,j) + MIN3(dtw2(j-1), dtw1(j), dtw1(j-1))
	*/
	float dtw(in float[VEC_DIM_MAX][] s, in float[VEC_DIM_MAX][] t)
	{
		float cost = 0;

		dtw1[] = float.max;
		dtw1[0] = 0;
		dtw2[0] = float.max;

		for (size_t i = 1; i < s.length; i++)
		{
			for (size_t j = 1; j < t.length; j++)
			{
				cost = localDistance(s[i], t[j]);
				dtw2[j] = cost + min(dtw2[j - 1], dtw1[j], dtw1[j - 1]);
			}

			auto tmp = dtw1;
			dtw1 = dtw2;
			dtw2 = tmp;
			dtw2[0] = float.max;
		}

		return dtw1[t.length - 1];
	}

	CharDist[] recognize(in ref Character ch, uint maxResults)
	{
		auto numVectors = ch.points.length;
		auto numStrokes = ch.numStrokes;
		auto input = ch.points;

		uint numChars, charID;

		foreach (ref group; groups)
		{
			if (group.n_strokes > (numStrokes + windowSize))
				break;
			if (numStrokes > windowSize && group.n_strokes < (numStrokes + windowSize))
			{
				charID += group.n_chars;
				continue;
			}

			(() @trusted{
				auto cursor = cast(float*)(data.ptr + group.offset);

				for (int i = 0; i < group.n_chars; i++)
				{
					distm[numChars].unicode = characters[charID].unicode;
					distm[numChars].distance = dtw(input,
						(cast(float[VEC_DIM_MAX]*) cursor)[0 .. characters[charID].n_vectors]);
					cursor += characters[charID].n_vectors * VEC_DIM_MAX;
					charID++;
					numChars++;
				}
			})();
		}

		auto size = min(numChars, maxResults);

		CharDist[] results = new CharDist[size];
		int i;

		foreach (res; distm[0 .. numChars].sort!((a, b) => charDistCmp(a, b) < 0
				? true : false).take(maxResults))
			results[i++] = res;

		return results;
	}
}

int charDistCmp(in CharDist a, in CharDist b)
{
	if (a.distance < b.distance)
		return -1;
	if (a.distance > b.distance)
		return 1;
	return 0;
}

///
unittest
{
	Recognizer r = Recognizer(2);
	r.load("/usr/share/tegaki/models/wagomu/joyo-kanji.model");
	// this model is on a 1000x1000 canvas

	Character ch = Character(100, 1);
	for (int x = 0; x < 10; x++)
		ch.points[x] = [x * 80 + 100, 500, 0, 0];
	auto res = r.recognize(ch, 5);

	assert(res[0].unicode == '一');
}
