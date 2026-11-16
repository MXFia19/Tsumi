<script>
  import { modal } from '@/modules/navigation.js'
  import { modalLayer } from '@/modules/modalstack.js'

  export let id
  export let showModal
  export let shouldRender = false
  export let close
  export let css = ''
  export let innerCss = ''
  export let label = ''
</script>

<!-- A layer of the modal stack (modules/modalstack.js): Esc closes the top layer only, focus moves in and back. -->
<div class='modal-soft position-absolute d-flex align-items-center justify-content-center z-50 w-full h-full {css}' class:hide={!showModal} class:show={showModal} id={`${id}_modal`}
  role='dialog' aria-modal='true' aria-label={label || undefined} aria-hidden={showModal ? undefined : 'true'}
  use:modalLayer={{ open: !!showModal, close, priority: modal.priority(id) }}>
  <div class='modal-soft-dialog d-flex align-items-center justify-content-center pt-40 {innerCss}' role='presentation' class:hide={!showModal} class:show={showModal} on:pointerdown|self={close}>
    <div class='overflow-hidden d-flex flex-column overflow-y-scroll scroll-container {$$restProps.class}'>
      {#if showModal || shouldRender}
        <slot></slot>
      {/if}
    </div>
  </div>
</div>

<style>
  .pt-40 {
    padding-top: 4rem;
  }
  .modal-soft {
    background-color: hsla(var(--black-color-hsl), 0.85);
    transition: opacity .2s ease-in-out, visibility .2s ease-in-out;
  }
  .modal-soft.show {
    visibility: visible;
    opacity: 1;
  }
  .modal-soft.hide {
    visibility: hidden;
    opacity: 0;
  }
  .modal-soft-dialog {
    width: 100%;
    height: 100%;
    transition: transform .2s ease-in-out;
    transform-origin: bottom center;
  }
  .modal-soft-dialog.show {
    transform: scale(1);
  }
  .modal-soft-dialog.hide {
    transform: scale(0.95);
  }
  .modal-soft-dialog:focus-visible {
    box-shadow: unset !important;
  }
</style>
