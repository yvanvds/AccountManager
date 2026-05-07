using AccountManager.Utils;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Input;

namespace AccountManager.ViewModels
{
    public interface IAsyncCommand : ICommand {
        Task ExecuteAsync();
        bool CanExecute();
    }

    class RelayAsyncCommand : IAsyncCommand
    {
        public event EventHandler CanExecuteChanged;

        private bool isExecuting;
        private readonly Func<Task> execute;
        private readonly Func<bool> canExecute;
        private readonly IErrorHandler errorHandler;

        public RelayAsyncCommand(
          Func<Task> execute,
          Func<bool> canExecute = null,
          IErrorHandler errorHandler = null
        )
        {
            this.execute = execute;
            this.canExecute = canExecute;
            this.errorHandler = errorHandler;
        }

        public bool CanExecute()
        {
            return !isExecuting && (canExecute?.Invoke() ?? true);
        }

        public async Task ExecuteAsync()
        {
            //if (CanExecute())
            {
                try
                {
                    isExecuting = true;
                    await execute();
                }
                finally
                {
                    isExecuting = false;
                }
            }

            RaiseCanExecuteChanged();
        }

        private void RaiseCanExecuteChanged()
        {
            CanExecuteChanged?.Invoke(this, EventArgs.Empty);
        }

        bool ICommand.CanExecute(object paramater)
        {
            return true;
            //return CanExecute();
        }

        void ICommand.Execute(object parameter)
        {
            ExecuteAsync().FireAndForgetSafeAsync(errorHandler);
        }
    }

    public interface IAsyncCommand<T> : ICommand
    {
        Task ExecuteAsync(T parameter);
        bool CanExecute(T parameter);
    }

    public class RelayAsyncCommand<T> : IAsyncCommand<T>
    {
        public event EventHandler CanExecuteChanged;

        private bool _isExecuting;
        private readonly Func<T, Task> _execute;
        private readonly Func<T, bool> _canExecute;
        private readonly IErrorHandler _errorHandler;

        public RelayAsyncCommand(Func<T, Task> execute, Func<T, bool> canExecute = null, IErrorHandler errorHandler = null)
        {
            _execute = execute;
            _canExecute = canExecute;
            _errorHandler = errorHandler;
        }

        public bool CanExecute(T parameter)
        {
            return !_isExecuting && (_canExecute?.Invoke(parameter) ?? true);
        }

        public async Task ExecuteAsync(T parameter)
        {
            if (CanExecute(parameter))
            {
                try
                {
                    _isExecuting = true;
                    await _execute(parameter);
                }
                finally
                {
                    _isExecuting = false;
                }
            }

            RaiseCanExecuteChanged();
        }

        public void RaiseCanExecuteChanged()
        {
            CanExecuteChanged?.Invoke(this, EventArgs.Empty);
        }

        #region Explicit implementations
        bool ICommand.CanExecute(object parameter)
        {
            return CanExecute((T)parameter);
        }

        void ICommand.Execute(object parameter)
        {
            ExecuteAsync((T)parameter).FireAndForgetSafeAsync(_errorHandler);
        }
        #endregion
    }
}
