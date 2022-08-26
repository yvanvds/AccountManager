using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.ViewModels.Actions
{
    class QRCodeAction : INotifyPropertyChanged
    {
        public IAsyncCommand QRCodeCommand { get; private set; }

        public QRCodeAction()
        {
            QRCodeCommand = new RelayAsyncCommand(Sync);
        }

        private async Task Sync()
        {
            Indicator = true;
            await (State.App.Instance.Smartschool.Groups.Root as AccountApi.Smartschool.Group).UpdateQRCodes().ConfigureAwait(false);
            Indicator = false;
        }

        public event PropertyChangedEventHandler PropertyChanged = (sender, e) => { };

        bool indicator = false;
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
