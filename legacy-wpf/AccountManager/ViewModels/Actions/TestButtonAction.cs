using AccountApi;
using AccountManager.State.Linked;
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.ViewModels.Actions
{
    internal class TestButtonAction : INotifyPropertyChanged
    {
        public IAsyncCommand TestButtonCommand { get; private set; }

    public TestButtonAction()
    {
        TestButtonCommand = new RelayAsyncCommand(Sync);
    }

    private async Task Sync()
    {
        Indicator = true;

            // add test here
            await AccountApi.Azure.UserManager.Instance.GetPasswordMethodId("yvan.vandersanden@arcadiascholen.be").ConfigureAwait(false);

            // end of test

            Indicator = false;
    }

    public event PropertyChangedEventHandler PropertyChanged = (sender, e) => { };

    bool indicator;
    public bool Indicator
    {
        get => indicator;
        set
        {
            indicator = value;
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(Indicator)));
        }
    }
}
}
