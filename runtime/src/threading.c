#include <debug.h>
#include <error.h>
#include <interpreter.h>
#include <module.h>
#include <pthread.h>
#include <threading.h>
#include <unistd.h>
#include <value.h>

Value list_get(Value list, uint32_t idx) {
  HeapValue *l = GET_PTR(list);
  if (idx < 0 || idx >= l->length) THROW_FMT("Invalid index, received %d", idx);

  return l->as_ptr[idx];
}

Value call_threaded(Module *module, Value callee, int32_t argc, Value *argv, int ls) {
  Module *new_module = malloc(sizeof(Module));
  new_module->stack = stack_new();
  
  pthread_mutex_lock(&module->module_mutex);
  int sp = module->stack->stack_pointer;
  for (int i = 0; i < sp; i++) stack_push(new_module->stack, module->stack->values[i]);
  pthread_mutex_unlock(&module->module_mutex);
  
  for (int i = 0; i < argc; i++) stack_push(new_module->stack, argv[i]);

  int16_t ipc = (int16_t)(callee & MASK_PAYLOAD_INT);
  // int16_t local_space = (int16_t)((callee >> 16) & MASK_PAYLOAD_INT);
  int16_t old_sp = new_module->stack->stack_pointer - argc;

  int32_t new_pc = module->pc + 4;

  // DEBUG_STACK(new_module->stack);
  pthread_mutex_lock(&module->module_mutex);
  stack_push(new_module->stack,
             MAKE_FRAME(module->gc, new_pc, old_sp, module->base_pointer));
  pthread_mutex_unlock(&module->module_mutex);

  new_module->base_pointer = new_module->stack->stack_pointer - (1 + ls);
  new_module->callstack = 1;

  pthread_mutex_lock(&module->module_mutex);
  new_module->instr_count = module->instr_count;
  new_module->instrs = module->instrs;
  new_module->constants = module->constants;
  new_module->gc = module->gc;
  new_module->argc = module->argc;
  new_module->argv = module->argv;
  pthread_mutex_unlock(&module->module_mutex);
  // module->pc = new_pc;
  Value ret = run_interpreter(new_module, ipc, true, new_module->callstack - 1);

  return ret;
}

void *actor_run(void *arg) {
  Actor *actor = (Actor *)arg;
  while (1) {
    Message *msg = dequeue(actor->queue);
    
    struct Event event = actor->event;
    Value *args = msg->args;
    int argc = msg->argc;
    int id = msg->name;

    Value *ons = event.ons;
    Value event_func = ons[id];

    call_threaded(actor->mod, event_func, argc, args, event.lets_count);
    
    free(msg->args);
    free(msg);
  }
  return NULL;
}

Actor *create_actor(struct Event event, struct Module* mod) {
  Actor *actor = malloc(sizeof(Actor));
  actor->queue = create_message_queue();
  actor->event = event;
  actor->mod = mod;

  pthread_create(&actor->thread, NULL, actor_run, actor);
  
  mod->events[mod->event_count++] = actor;

  return actor;
}

void send_message(Actor *actor, int name, Value *args, int argc) {
  Message *msg = malloc(sizeof(Message));
  msg->args = args;
  msg->name = name;
  msg->argc = argc;
  msg->next = NULL;
  enqueue(actor->queue, msg);
}