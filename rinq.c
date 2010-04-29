
// read "rinq" as "ring-queue"

struct rinq {
    struct rinq *next;
    struct rinq *prev;
    void *ref;
};

#define RINQ_IS_UNINIT(x_) ((x_)->next == NULL && (x_)->prev == NULL)
#define RINQ_IS_DETACHED(x_) ((x_)->next == (x_)) 
#define RINQ_IS_ATTACHED(x_) ((x_)->next != (x_)) 

#define RINQ_NEW(x_,ref_) do { \
    x_ = (struct rinq *)malloc(sizeof(struct rinq)); \
    x_->next = x_->prev = x_; \
    x_->ref = ref_; \
} while(0)
 
#define RINQ_DETACH(x_) do { \
    (x_)->next->prev = (x_)->prev; \
    (x_)->prev->next = (x_)->next; \
    (x_)->next = (x_)->prev = (x_); \
} while(0)
 
static void
rinq_unshift(struct rinq **head, void *ref)
{
    struct rinq *x;
    RINQ_NEW(x,ref);

    if ((*head) != NULL) {
        x->next = (*head)->next;
        x->prev = (*head);
        x->next->prev = x->prev->next = x;
    }
    (*head) = x;
}
 
static void
rinq_push (struct rinq **head, void *ref)
{
    struct rinq *x;
    RINQ_NEW(x,ref);

    if ((*head) == NULL) {
        (*head) = x;
    }
    else {
        x->next = (*head);
        x->prev = (*head)->prev;
        x->next->prev = x->prev->next = x;
    }
}

// remove element from tail of rinq
static void *
rinq_pop (struct rinq **head) {
    void *ref;
    struct rinq *x;

    if ((*head) == NULL) return NULL;

    if (RINQ_IS_DETACHED((*head))) {
        x = (*head);
        (*head) = NULL;
    }
    else {
        x = (*head)->prev;
        RINQ_DETACH(x);
    }

    ref = x->ref;
    free(x);
    return ref;
}

// remove element from head of rinq
static void *
rinq_shift (struct rinq **head) {
    void *ref;
    struct rinq *x;

    if ((*head) == NULL) return NULL;

    if (RINQ_IS_DETACHED((*head))) {
        x = (*head);
        (*head) = NULL;
    }
    else {
        x = (*head);
        (*head) = (*head)->next;
        RINQ_DETACH(x);
    }

    ref = x->ref;
    free(x);
    return ref;
}
