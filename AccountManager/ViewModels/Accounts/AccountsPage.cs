using AccountManager.State;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.ViewModels.Accounts
{
    public class AccountsPage : BaseViewModel, IStateObserver
    {
        public AccountsPage()
        {
            
            State.App.Instance.Settings.AddObserver(this);
        }

        ~AccountsPage()
        {
            State.App.Instance.Settings.RemoveObserver(this);
        }

        public bool DebugMode { get; set; } = State.App.Instance.Settings.DebugMode.Value;

        public void OnStateChanges()
        {
            Utils.Set.IfNew(State.App.Instance.Settings.DebugMode.Value, DebugMode);
        }
    }
}
