# wagomu

slightly modified wagomu engine from tegaki project ported to D.

Grab a wagomu model from https://tegaki.github.io/ and load and use it using:

```d
import wagomu;

Recognizer r = Recognizer(2); // 2 = how many strokes the drawn characters can be off the actual character

r.load("/usr/share/tegaki/models/wagomu/joyo-kanji.model"); // put your model path in here
// this model uses a canvas of 1000x1000, check the xml file with your model for info

Character ch = Character(20, 1); // point count, stroke count
for (int x = 0; x < 10; x++)
	ch.points[x] = [x * 80 + 100, 500, 0, 0]; // generate straight line from x 100 to 900, y = 500
// you can use user input here
// argument 3 and 4 are unused in this model, they might be associated with input like pressure or thickness, depending on the model
// points must be in stroke order, density should be roughly 50 pixels apart each point for this model (10 points per straight line)
// higher density still works but the higher the density is, the more likely it is going to compare with characters with lots of strokes

auto res = r.recognize(ch, 5); // returns up to 5 suggestions for this character, best suggestion first

assert(res[0].unicode == '一');
```