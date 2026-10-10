// The prompts are the app's own files, so a word written through the server and one written with the user's own key
// are asked for in the same words.
import pictureBrief from '../../Cue/Resources/Prompts/picture-brief.txt';
import entryInstructions from '../../Cue/Resources/Prompts/entry-instructions.txt';
import entrySchema from '../../Cue/Resources/Prompts/entry-schema.txt';
import saferBriefInstructions from '../../Cue/Resources/Prompts/safer-brief-instructions.txt';
import pictureStyle from '../../Cue/Resources/Prompts/picture-style.txt';
import chatManner from '../../Cue/Resources/Prompts/chat-manner.txt';
import chatWall from '../../Cue/Resources/Prompts/chat-wall.txt';
import chatWord from '../../Cue/Resources/Prompts/chat-word.txt';
import decideInstructions from '../../Cue/Resources/Prompts/decide-instructions.txt';
import speechInstructions from '../../Cue/Resources/Prompts/speech-instructions.txt';

/** A prompt with its {{placeholders}} filled in, as the app fills them (`Prompts.text`). */
function fill(text: string, values: Record<string, string>): string {
  return text.replace(/\{\{(\w+)\}\}/g, (whole, name: string) => values[name] ?? whole);
}

export const prompts = {
  entryInstructions: fill(entryInstructions, { pictureBrief }),
  /** Parsed and sent as written: the model writes the fields in this order. */
  entrySchema: JSON.parse(entrySchema) as unknown,
  saferBriefInstructions: fill(saferBriefInstructions, { pictureBrief }),
  pictureStyle,
  chat(kind: 'wall' | 'word', lines: string[]): string {
    return chatManner + (kind === 'wall'
      ? fill(chatWall, { saved: lines.join('\n') })
      : fill(chatWord, { page: lines.join('\n') }));
  },
  decideInstructions,
  speechInstructions,
};
