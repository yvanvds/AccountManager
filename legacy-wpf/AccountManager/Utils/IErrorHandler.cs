using System;

namespace AccountManager.Utils
{
    public interface IErrorHandler
    {
        void HandleError(Exception ex);
    }
}
