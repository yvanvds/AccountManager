using AccountManager.State;
using AccountManager.Utils;
using Microsoft.Win32;
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Input;

namespace AccountManager.ViewModels.Settings
{
    class GeneralSettings : INotifyPropertyChanged
    {
        #region commands
        public ICommand ExportCommand { get; set; }
        public ICommand ImportCommand { get; set; }

        public GeneralSettings()
        {
            this.ExportCommand = new RelayCommand(Export);
            this.ImportCommand = new RelayCommand(Import);
        }

        private void Export()
        {
            var dialog = new SaveFileDialog();
            dialog.Filter = "json file (.json)|*.json";

            if (dialog.ShowDialog() == true)
            {
                State.App.Instance.SaveConfiguration(dialog.FileName);
            }
        }

        private void Import()
        {
            var dialog = new OpenFileDialog();
            dialog.Filter = "json file (.json)|*.json";

            if (dialog.ShowDialog() == true)
            {
                State.App.Instance.LoadConfiguration(dialog.FileName);
                State.App.Instance.SaveConfiguration(State.App.GetConfigFilePath());
            }
        }
        #endregion

        #region properties
        public event PropertyChangedEventHandler PropertyChanged = (sender, e) => { };
        public bool DebugMode { 
            get => State.App.Instance.Settings.DebugMode.Value; 
            set {
                State.App.Instance.Settings.DebugMode.Value = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(DebugMode)));
            } 
        }
        public bool WorkDateIsNow { 
            get => State.App.Instance.Wisa.WorkDateIsNow.Value;
            set {
                State.App.Instance.Wisa.WorkDateIsNow.Value = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(WorkDateIsNow)));
            } 
        }
        public DateTime WorkDate { 
            get => State.App.Instance.Wisa.WorkDate.Value;
            set
            {
                State.App.Instance.Wisa.WorkDate.Value = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(WorkDate)));
            }
        }
        #endregion

    }
}
