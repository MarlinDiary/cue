import { authenticate } from './account';
import { type Env, HttpError, json } from './env';
import * as routes from './routes';

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    try {
      const { pathname } = new URL(request.url);
      const route = `${request.method} ${pathname}`;
      if (route === 'POST /v1/apple/notifications') return await routes.appleNotification(request, env);
      const account = await authenticate(request, env);
      switch (route) {
        case 'GET /v1/account': return await routes.account(env, account);
        case 'POST /v1/entry': return await routes.entry(request, env, ctx, account);
        case 'POST /v1/picture': return await routes.picture(request, env, ctx, account);
        case 'POST /v1/brief': return await routes.brief(request, env, account);
        case 'POST /v1/chat': return await routes.chat(request, env, ctx, account);
        case 'POST /v1/speech': return await routes.speech(request, env, account);
        case 'POST /v1/decide': return await routes.decide(request, env, account);
        case 'POST /v1/offer': return await routes.offer(request, env, account);
        case 'POST /v1/note': return await routes.note(request, env, account);
        case 'POST /v1/split': return await routes.split(request, env, account);
        case 'POST /v1/count': return await routes.count(request, env, account);
        case 'POST /v1/purchase': return await routes.purchase(request, env, account);
        case 'POST /v1/dev/grant': return await routes.grant(request, env, account);
        default: throw new HttpError(404, 'not_found', 'Not found.');
      }
    } catch (error) {
      if (error instanceof HttpError) return error.response();
      if (error instanceof SyntaxError) return json({ error: { code: 'bad_request', message: 'Not JSON.' } }, 400);
      console.error(error);
      return json({ error: { code: 'server_error', message: 'Something went wrong on Cue’s server.' } }, 500);
    }
  },
} satisfies ExportedHandler<Env>;
