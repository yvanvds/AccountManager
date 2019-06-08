using AbstractAccountApi;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action
{
    public class RemoveDirectoryClassGroup : GroupAction
    {
        public RemoveDirectoryClassGroup() : base(
            "Active Directory Klas Verwijderen",
            "Je kan deze klas niet verwijderen uit Active Directory omdat " +
            "ze niet leeg is. Verwijder of verplaats eerst de leerlingen in deze klas.",
            false)
        { }

        public override Task Apply(LinkedGroup linkedGroup)
        {
            throw new NotImplementedException();
        }
    }
}
